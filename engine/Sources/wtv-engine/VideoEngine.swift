import CoreVideo
import Foundation
import Logging
import WTVAudio
import WTVCore
import WTVOutputs
import WTVProtocol
import WTVVideo

/// Liga o estado (StateStore) ao compositor, ao relógio e aos codificadores de preview.
final class VideoEngine: PreviewSource, @unchecked Sendable {
    let store: StateStore
    let metal: MetalContext
    let frames = FrameStore()
    let compositor: Compositor
    let hub = PreviewHub()
    private let log = Logger(label: "wtv.video")

    private var planLock = os_unfair_lock()
    private var plan: RenderPlan
    private var clock: VideoClock?
    private var clockRate: FrameRate
    private var multiviewEncoder: PreviewEncoder?
    private var multiviewDivider: Int64 = 2

    // Transição automática em curso
    private var transitionStartTick: Int64?
    private var transitionCompletionSent = false
    private var transitionRev = -1

    // Últimos buffers (para snapshot PNG)
    private var lastLock = os_unfair_lock()
    private var last: RenderedFrame?
    private var lastMultiview: CVPixelBuffer?

    // Áudio (D7): o plano de mistura segue o estado e o progresso da transição (AFV)
    let mixer: AudioMixer?
    private var monitorDeviceId: String?
    private var lastState: EngineState
    private var lastAudioProgress = -1.0
    private var meterTimer: DispatchSourceTimer?
    private let audioPlanQueue = DispatchQueue(label: "wtv.audio.plan", qos: .userInitiated)

    var outputs: OutputManager?

    private var subscription: UUID?
    private var planTask: Task<Void, Never>?
    private var lastErrorLog: UInt64 = 0

    init(store: StateStore) async throws {
        self.store = store
        metal = try MetalContext()
        compositor = Compositor(metal: metal, frames: frames)
        let state = await store.state
        plan = RenderPlan(state: state)
        lastState = state
        clockRate = FrameRate(fps: state.project.raster.fps) ?? FrameRate(fps: 50)!
        let m = AudioMixer()
        m.setPlan(MixPlan(state: state, transitionProgress: 0))
        mixer = m
        hub.onNewSubscriber = { [weak self] _ in self?.multiviewEncoder?.requestKeyframe() }
        try rebuildMultiviewEncoder(size: plan.multiviewSize)
    }

    private func rebuildMultiviewEncoder(size: (Int, Int)) throws {
        let fps = Int((clockRate.fps / Double(multiviewDivider)).rounded())
        multiviewEncoder = try PreviewEncoder(stream: .multiview, width: size.0, height: size.1, fps: max(fps, 10), bitrate: 5_000_000) { [hub] data in
            hub.publish(stream: "multiview", data)
        }
    }

    func start() async {
        let (id, patches) = await store.subscribe()
        subscription = id
        planTask = Task { [weak self] in
            for await _ in patches {
                guard let self else { return }
                let state = await self.store.state
                self.update(state: state)
            }
        }
        startClock()
        startMeters()
        await openAudio(deviceUID: lastState.audio.monitor.deviceId)
        log.info("vídeo a correr a \(clockRate.fps) fps, multiview \(plan.multiviewSize.0)x\(plan.multiviewSize.1)")
    }

    /// Abre o dispositivo de monitorização numa thread própria (o coreaudiod pode não responder; ver AMBIENTE.md).
    private func openAudio(deviceUID: String?) async {
        guard let mixer else { return }
        monitorDeviceId = deviceUID
        // Primeiro a listagem (só consultas), depois a abertura; ambas fora das threads cooperativas.
        let (devices, status) = await withCheckedContinuation { (c: CheckedContinuation<(([AudioDevice], [AudioDevice]), AudioOutputStatus), Never>) in
            let t = Thread {
                let list = AudioMixer.listDevicesSafely()
                let st = mixer.openOutput(deviceUID: deviceUID)
                c.resume(returning: ((list.output, list.input), st))
            }
            t.name = "wtv.audio.open.wait"
            t.start()
        }
        await store.mutate { s in
            if !devices.0.isEmpty { s.devices.audioOut = devices.0 }
            if !devices.1.isEmpty { s.devices.audioIn = devices.1 }
            s.alarms.removeAll { $0.code == "AUDIO_OUTPUT" }
            if case .nullClock(let reason) = status {
                s.alarms.append(Alarm(code: "AUDIO_OUTPUT", level: "warning", detail: "Monitorização de áudio desligada: \(reason)"))
            }
        }
        switch status {
        case .device(let name, let rate, let ch): log.info("áudio: \(name) \(Int(rate)) Hz \(ch) canais")
        case .nullClock(let reason): log.warning("áudio em relógio nulo: \(reason)")
        case .none: break
        }
    }

    private func startMeters() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "wtv.meters"))
        t.schedule(deadline: .now(), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in
            guard let self, let mixer = self.mixer, self.hub.totalCount > 0 else { return }
            os_unfair_lock_lock(&self.planLock); let order = self.lastState.inputOrder; os_unfair_lock_unlock(&self.planLock)
            let payload = mixer.metersFrame(order: order)
            let msg = PreviewFrame.encode(stream: .meters, flags: [], codec: .none, seq: 0,
                                          ptsMicros: UInt64(DispatchTime.now().uptimeNanoseconds / 1000), config: nil, payload: payload)
            self.hub.publishAll(msg)
        }
        t.resume()
        meterTimer = t
    }

    private func startClock() {
        multiviewDivider = clockRate.fps > 31 ? 2 : 1
        let c = VideoClock(frameRate: clockRate) { [weak self] n, host in self?.tick(n, host) }
        clock = c
        c.start()
    }

    private func update(state: EngineState) {
        let newPlan = RenderPlan(state: state)
        var restartClock = false
        if let fr = FrameRate(fps: state.project.raster.fps), fr != clockRate {
            clockRate = fr
            restartClock = true
        }
        let sizeChanged = newPlan.multiviewSize != plan.multiviewSize
        os_unfair_lock_lock(&planLock)
        plan = newPlan
        lastState = state
        lastAudioProgress = -1
        if newPlan.transition == nil {
            transitionStartTick = nil
            transitionCompletionSent = false
        }
        os_unfair_lock_unlock(&planLock)
        if restartClock {
            clock?.stop()
            startClock()
        }
        if restartClock || sizeChanged {
            do { try rebuildMultiviewEncoder(size: newPlan.multiviewSize) } catch { log.error("codificador multiview: \(error)") }
        }
        if state.audio.monitor.deviceId != monitorDeviceId {
            let uid = state.audio.monitor.deviceId
            monitorDeviceId = uid
            Task { await self.openAudio(deviceUID: uid) }
        }
    }

    private func tick(_ n: Int64, _ hostNanos: UInt64) {
        os_unfair_lock_lock(&planLock)
        let plan = self.plan
        var progress = 0.0
        if let t = plan.transition {
            if t.auto {
                if transitionStartTick == nil || transitionRev != plan.rev {
                    if transitionRev != plan.rev && transitionStartTick == nil { transitionStartTick = n }
                    transitionRev = plan.rev
                }
                let start = transitionStartTick ?? n
                progress = Double(n - start) / Double(max(1, t.durationFrames))
                if progress >= 1 {
                    progress = 1
                    if !transitionCompletionSent {
                        transitionCompletionSent = true
                        Task { await self.completeTransition() }
                    }
                }
            } else {
                progress = t.manualProgress
            }
        }
        if mixer != nil, abs(progress - lastAudioProgress) >= 0.02 || (progress == 0 && lastAudioProgress != 0) || (progress == 1 && lastAudioProgress != 1) {
            lastAudioProgress = progress
            let state = lastState
            // Fora da thread de vídeo (D18): construir o plano aloca memória.
            audioPlanQueue.async { [weak self] in self?.mixer?.setPlan(MixPlan(state: state, transitionProgress: progress)) }
        }
        os_unfair_lock_unlock(&planLock)

        let renderMV = n % multiviewDivider == 0
        do {
            let outputs = self.outputs
            let frame = try compositor.render(plan: plan, tick: n, hostTimeNanos: hostNanos, transitionProgress: progress, renderMultiview: renderMV,
                                              encodeProgram: outputs?.needsProgramNV12 ?? false,
                                              beforeCommit: outputs.map { o in { cmd, prog, mv in o.beforeCommit(cmd, program: prog, multiview: mv) } })
            outputs?.didRender(frame)
            os_unfair_lock_lock(&lastLock)
            last = frame
            if let mv = frame.multiview { lastMultiview = mv }
            os_unfair_lock_unlock(&lastLock)
            if let nv12 = frame.multiviewNV12, hub.count(stream: "multiview") > 0 {
                multiviewEncoder?.encode(nv12, ptsMicros: hostNanos / 1000)
            }
        } catch {
            if hostNanos - lastErrorLog > 1_000_000_000 {
                lastErrorLog = hostNanos
                log.error("tick \(n): \(error)")
            }
        }
    }

    private func completeTransition() async {
        await store.mutate { s in
            guard s.program.transition != nil else { return }
            let pvw = s.preview.inputId
            s.preview.inputId = s.program.inputId
            s.program.inputId = pvw
            s.program.transition = nil
        }
    }

    var clockStats: VideoClock.Stats { clock?.currentStats ?? VideoClock.Stats() }

    // MARK: - PreviewSource

    func subscribe(stream: String) -> (UUID, AsyncStream<Data>)? {
        guard stream == "multiview" else { return nil } // "program" chega com o codificador de Program
        return hub.subscribe(stream: stream)
    }

    func unsubscribe(_ id: UUID) { hub.unsubscribe(id) }

    func snapshotPNG(bus: String) -> Data? {
        os_unfair_lock_lock(&lastLock); let f = last; let mv = lastMultiview; os_unfair_lock_unlock(&lastLock)
        guard let f else { return nil }
        switch bus {
        case "preview": return Compositor.pngData(from: f.preview)
        case "multiview": return mv.flatMap { Compositor.pngData(from: $0) }
        default: return Compositor.pngData(from: f.program)
        }
    }
}
