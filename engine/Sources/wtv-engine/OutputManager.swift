import AVFoundation
import Foundation
import Logging
import Metal
import WTVAudio
import WTVCore
import WTVOutputs
import WTVProtocol
import WTVVideo

/// Saídas do Program (D11, D15, D16): um codificador partilhado alimenta gravador e RTMP; NDI e projector
/// recebem o BGRA do compositor. A parte de controlo corre numa fila serial; a thread de vídeo só lê.
final class OutputManager: @unchecked Sendable {
    private let store: StateStore
    private let mixer: AudioMixer?
    private let files: EngineFiles
    private let device: MTLDevice
    private let log = Logger(label: "wtv.outputs")
    private let queue = DispatchQueue(label: "wtv.outputs")

    private var lock = os_unfair_lock()
    /// Secção crítica síncrona (os_unfair_lock não pode ser usado directamente em funções async).
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return try body()
    }
    private var encoder: ProgramEncoder?
    private var recorder: Recorder?
    private var rtmp: [OutputId: RTMPOutput] = [:]
    private var srt: [OutputId: SRTOutput] = [:]
    private var ndi: NDIOutput?
    private var ndiOutputId: OutputId?
    private var projector: Projector?
    private var secrets: [OutputId: String] = [:]
    private var audioTimer: DispatchSourceTimer?
    private var audioScratch = [Float](repeating: 0, count: 4800 * 2)
    private var ndiScratch = [Float](repeating: 0, count: 4800 * 2)
    private var statsTimer: DispatchSourceTimer?
    private var raster = Raster.hd50

    init(store: StateStore, mixer: AudioMixer?, files: EngineFiles, device: MTLDevice) {
        self.store = store
        self.mixer = mixer
        self.files = files
        self.device = device
        loadSecrets()
    }

    // MARK: - Chamado pela thread de vídeo

    var needsProgramNV12: Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return (encoder?.sinkCount ?? 0) > 0
    }

    var hasProjector: Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return projector != nil
    }

    func beforeCommit(_ cmd: MTLCommandBuffer, program: MTLTexture, multiview: MTLTexture?) {
        // Nada de bloqueante aqui (thread de vídeo): o projector apresenta na sua própria thread.
        os_unfair_lock_lock(&lock); let p = projector; let src = projectorSource; os_unfair_lock_unlock(&lock)
        guard let p else { return }
        if src == "multiview", let multiview { p.submit(multiview) } else { p.submit(program) }
    }
    private var projectorSource = "program"

    func didRender(_ frame: RenderedFrame) {
        os_unfair_lock_lock(&lock); let enc = encoder; let n = ndi; os_unfair_lock_unlock(&lock)
        if let enc, let nv12 = frame.programNV12 { enc.encodeVideo(nv12, hostTimeNanos: frame.hostTimeNanos) }
        n?.send(video: frame.program, hostTimeNanos: frame.hostTimeNanos)
    }

    // MARK: - Arranque / estado

    func start() async {
        raster = await store.state.project.raster
        startAudioTap()
        startStats()
        let (_, patches) = await store.subscribe()
        Task { [weak self] in
            for await _ in patches {
                guard let self else { return }
                let s = await self.store.state
                self.reconcile(s)
            }
        }
        reconcile(await store.state)
    }

    private func reconcile(_ s: EngineState) {
        queue.async { [self] in
            raster = s.project.raster
            // projector segue o estado
            os_unfair_lock_lock(&lock)
            let current = projector
            projectorSource = s.projector.source
            os_unfair_lock_unlock(&lock)
            if let id = s.projector.displayId {
                // Segurança: ecrã inteiro só num ecrã que não seja o principal (onde está a interface).
                // No único ecrã do Mac abre sempre em janela; a janela fecha com Esc.
                let display = s.devices.displays.first { $0.id == id }
                let fullscreen = s.projector.fullscreen && !(display?.isMain ?? true)
                if current == nil || current!.displayId != id || current!.fullscreen != fullscreen {
                    current?.close()
                    let p = Projector(device: device, displayId: id, fullscreen: fullscreen, size: (s.project.raster.width, s.project.raster.height))
                    p.onClose = { [weak self] in
                        guard let self else { return }
                        Task { await self.store.mutate { $0.projector.displayId = nil } }
                    }
                    os_unfair_lock_lock(&lock); projector = p; os_unfair_lock_unlock(&lock)
                    if s.projector.fullscreen && !fullscreen {
                        Task { await self.store.mutate { st in
                            st.projector.fullscreen = false
                            st.alarms.removeAll { $0.code == "PROJECTOR_WINDOWED" }
                            st.alarms.append(Alarm(code: "PROJECTOR_WINDOWED", level: "warning", detail: "O projector abriu em janela: o ecrã escolhido é o principal (onde está a interface). Ligue um segundo ecrã para ecrã inteiro."))
                        } }
                    }
                    log.info("projector no ecrã \(id) \(fullscreen ? "ecrã inteiro" : "janela")")
                }
            } else if current != nil {
                current?.close()
                os_unfair_lock_lock(&lock); projector = nil; os_unfair_lock_unlock(&lock)
                Task { await self.store.mutate { $0.alarms.removeAll { $0.code == "PROJECTOR_WINDOWED" } } }
            }
            ndi?.setFrameRate(s.project.raster.fps)
        }
    }

    private func ensureEncoder() throws -> ProgramEncoder {
        if let encoder { return encoder }
        let fps = Int(raster.fps.rounded())
        let bitrate = raster.width >= 3840 ? 16_000_000 : (fps > 30 ? 8_000_000 : 6_000_000)
        let e = try ProgramEncoder(profile: .init(width: raster.width, height: raster.height, fps: fps, videoBitrate: bitrate))
        os_unfair_lock_lock(&lock); encoder = e; os_unfair_lock_unlock(&lock)
        log.info("codificador Program \(raster.width)x\(raster.height)@\(fps) \(bitrate / 1000) kbps")
        return e
    }

    private func releaseEncoderIfIdle() {
        os_unfair_lock_lock(&lock)
        if let e = encoder, e.sinkCount == 0 { encoder = nil }
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Comandos (do CommandRouter)

    func command(_ method: String, params: JSONValue) async throws {
        switch method {
        case "output.add", "output.update":
            if let id = params["_outputId"]?.stringValue, let key = params["config"]?["streamKey"]?.stringValue {
                withLock { secrets[id] = key.isEmpty ? nil : key }
                saveSecrets()
                let has = !key.isEmpty
                await store.mutate { $0.outputs[id]?.config.hasStreamKey = has }
            }
        case "project.loaded":
            let known = withLock { secrets }
            await store.mutate { s in for id in s.outputs.keys { s.outputs[id]?.config.hasStreamKey = known[id] != nil } }
        case "output.remove":
            if let id = params["outputId"]?.stringValue {
                withLock { secrets[id] = nil }
                saveSecrets()
            }
        case "output.start":
            guard let id = params["outputId"]?.stringValue, let out = await store.state.outputs[id] else { throw RpcErrorBody.domain("OUTPUT_NOT_FOUND") }
            try await startOutput(out)
        case "output.stop":
            guard let id = params["outputId"]?.stringValue else { throw RpcErrorBody.invalidParams("outputId") }
            await stopOutput(id)
        case "record.start":
            let rec = await store.state.recording
            try await startRecording(container: params["container"]?.stringValue ?? rec.container, folder: params["folder"]?.stringValue ?? rec.folder)
        case "record.stop":
            await stopRecording()
        default: break
        }
    }

    private func startOutput(_ out: OutputState) async throws {
        switch out.kind {
        case .rtmp:
            guard let url = out.config.url, !url.isEmpty else { throw RpcErrorBody.invalidParams("url") }
            let (key, existing) = withLock { (secrets[out.id] ?? "", rtmp[out.id]) }
            if existing != nil { throw RpcErrorBody.domain("ALREADY_RUNNING") }
            let enc = try ensureEncoder()
            let r = RTMPOutput(sinkId: out.id, url: url, streamKey: key)
            let id = out.id
            r.onStatus = { [weak self] st in
                guard let self else { return }
                Task {
                    await self.store.mutate { s in
                        guard s.outputs[id] != nil else { return }
                        switch st {
                        case .connecting: s.outputs[id]?.status = .starting
                        case .live: s.outputs[id]?.status = .live; s.outputs[id]?.startedAt = Date(); s.outputs[id]?.statusCode = nil
                        case .reconnecting(let n): s.outputs[id]?.status = .reconnecting; s.outputs[id]?.statusCode = "tentativa \(n)"
                        case .stopped: s.outputs[id]?.status = .stopped; s.outputs[id]?.startedAt = nil
                        case .error(let e): s.outputs[id]?.status = .reconnecting; s.outputs[id]?.statusCode = e
                        }
                    }
                }
            }
            withLock { rtmp[out.id] = r }
            enc.add(r)
            r.start()
            await store.mutate { $0.outputs[out.id]?.status = .starting }
        case .ndi:
            guard ndi == nil else { throw RpcErrorBody.domain("ALREADY_RUNNING", "só uma saída NDI") }
            let name = out.config.ndiName ?? "WTV Studio"
            guard let n = NDIOutput(name: name, fps: raster.fps) else {
                throw RpcErrorBody.domain("CAPABILITY_MISSING", NDIRuntime.shared.error.isEmpty ? "NDI" : NDIRuntime.shared.error)
            }
            withLock { ndi = n; ndiOutputId = out.id }
            await store.mutate { $0.outputs[out.id]?.status = .live; $0.outputs[out.id]?.startedAt = Date() }
            log.info("NDI a emitir como \(name)")
        case .srt:
            guard let url = out.config.url, !url.isEmpty else { throw RpcErrorBody.invalidParams("url") }
            let existing = withLock { srt[out.id] }
            if existing != nil { throw RpcErrorBody.domain("ALREADY_RUNNING") }
            let enc = try ensureEncoder()
            guard let r = SRTOutput(sinkId: out.id, url: url, latencyMs: out.config.latencyMs) else { throw RpcErrorBody.invalidParams("url srt:// inválido") }
            let id = out.id
            r.onStatus = { [weak self] st in
                guard let self else { return }
                Task {
                    await self.store.mutate { s in
                        guard s.outputs[id] != nil else { return }
                        switch st {
                        case .connecting: s.outputs[id]?.status = .starting
                        case .live: s.outputs[id]?.status = .live; s.outputs[id]?.startedAt = Date(); s.outputs[id]?.statusCode = nil
                        case .reconnecting(let n): s.outputs[id]?.status = .reconnecting; s.outputs[id]?.statusCode = "tentativa \(n)"
                        case .stopped: s.outputs[id]?.status = .stopped; s.outputs[id]?.startedAt = nil
                        case .error(let e): s.outputs[id]?.status = .reconnecting; s.outputs[id]?.statusCode = e
                        }
                    }
                }
            }
            withLock { srt[out.id] = r }
            enc.add(r)
            r.start()
            await store.mutate { $0.outputs[out.id]?.status = .starting }
        }
    }

    private func stopOutput(_ id: OutputId) async {
        let (r, sr): (RTMPOutput?, SRTOutput?) = withLock {
            let r = rtmp.removeValue(forKey: id)
            let sr = srt.removeValue(forKey: id)
            if ndiOutputId == id { ndi = nil; ndiOutputId = nil }
            return (r, sr)
        }
        if let r {
            encoder?.remove(id)
            await r.stop()
            releaseEncoderIfIdle()
        }
        if let sr {
            encoder?.remove(id)
            await sr.stop()
            releaseEncoderIfIdle()
        }
        await store.mutate { $0.outputs[id]?.status = .stopped; $0.outputs[id]?.startedAt = nil }
    }

    private func startRecording(container: String, folder: String?) async throws {
        guard recorder == nil else { throw RpcErrorBody.domain("ALREADY_RUNNING", "já está a gravar") }
        let dir = folder.map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("WTV Studio", isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { throw RpcErrorBody.domain("PERMISSION_DENIED", "não é possível usar a pasta \(dir.path)") }
        guard FileManager.default.isWritableFile(atPath: dir.path) else { throw RpcErrorBody.domain("PERMISSION_DENIED", "sem permissão de escrita em \(dir.path)") }
        if let free = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage, free < 1_000_000_000 {
            throw RpcErrorBody.domain("DISK_FULL", "menos de 1 GB livre")
        }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let url = dir.appendingPathComponent("WTV \(f.string(from: Date())).\(container == "mp4" ? "mp4" : "mov")")
        let enc = try ensureEncoder()
        let r = Recorder(sinkId: "record", url: url)
        r.audioFormatHint = enc.audioFormatDescription
        r.onError = { [weak self] code in
            guard let self else { return }
            Task { await self.store.mutate { $0.recording.status = "idle"; $0.alarms.append(Alarm(code: code, level: "critical", detail: "Gravação parou: \(code)")) } }
            Task { await self.stopRecording() }
        }
        withLock { recorder = r }
        enc.add(r)
        await store.mutate { s in
            s.recording.status = "recording"; s.recording.file = url.path; s.recording.startedAt = Date(); s.recording.bytes = 0; s.recording.container = container
        }
        log.info("a gravar em \(url.path)")
    }

    private func stopRecording() async {
        let r: Recorder? = withLock { let r = recorder; recorder = nil; return r }
        guard let r else { return }
        encoder?.remove("record")
        releaseEncoderIfIdle()
        await store.mutate { $0.recording.status = "stopping" }
        let bytes: Int64 = await withCheckedContinuation { c in r.stop { c.resume(returning: $0) } }
        await store.mutate { $0.recording.status = "idle"; $0.recording.bytes = Int(bytes) }
        log.info("gravação terminada (\(bytes / 1_000_000) MB)")
    }

    // MARK: - Áudio do master para codificador e NDI

    private func startAudioTap() {
        guard let mixer else { return }
        mixer.tapEnabled = true
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "wtv.outputs.audio", qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            os_unfair_lock_lock(&self.lock); let enc = self.encoder; let n = self.ndi; os_unfair_lock_unlock(&self.lock)
            let frames = mixer.masterRing.read(into: &self.audioScratch, frames: 4800)
            if frames > 0 {
                let host = HostClockNanos.now() &- UInt64(Double(frames) / AudioMixer.sampleRate * 1e9)
                self.audioScratch.withUnsafeBufferPointer { p in enc?.appendAudio(p.baseAddress!, frames: frames, hostTimeNanos: host) }
            }
            let nf = mixer.ndiRing.read(into: &self.ndiScratch, frames: 4800)
            if nf > 0, let n {
                let host = HostClockNanos.now() &- UInt64(Double(nf) / AudioMixer.sampleRate * 1e9)
                self.ndiScratch.withUnsafeBufferPointer { p in n.send(audioInterleaved: p.baseAddress!, frames: nf, hostTimeNanos: host) }
            }
        }
        t.resume()
        audioTimer = t
    }

    private func startStats() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            os_unfair_lock_lock(&self.lock); let rec = self.recorder; let rt = self.rtmp; let st = self.srt; os_unfair_lock_unlock(&self.lock)
            guard rec != nil || !rt.isEmpty || !st.isEmpty else { return }
            let bytes = rec?.bytes
            var rtmpStats = rt.mapValues { $0.stats }
            for (id, o) in st { rtmpStats[id] = (bytes: o.stats, dropped: 0) }
            Task {
                await self.store.mutate { s in
                    if let bytes, s.recording.status == "recording" { s.recording.bytes = Int(bytes) }
                    for (id, st) in rtmpStats {
                        guard var o = s.outputs[id] else { continue }
                        if o.status == .live { o.statusCode = "\(st.bytes / 1000) kB enviados" }
                        s.outputs[id] = o
                    }
                }
            }
        }
        t.resume()
        statsTimer = t
    }

    // MARK: - Segredos (chaves de stream). TODO Fase 2: Keychain.

    private var secretsURL: URL { files.dataDir.appendingPathComponent("secrets.json") }

    private func loadSecrets() {
        guard let data = try? Data(contentsOf: secretsURL), let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        secrets = dict
    }

    private func saveSecrets() {
        os_unfair_lock_lock(&lock); let copy = secrets; os_unfair_lock_unlock(&lock)
        if let data = try? JSONEncoder().encode(copy) {
            try? data.write(to: secretsURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretsURL.path)
        }
    }
}

enum HostClockNanos {
    private static let tb: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
    static func now() -> UInt64 { mach_absolute_time() * UInt64(tb.numer) / UInt64(tb.denom) }
}
