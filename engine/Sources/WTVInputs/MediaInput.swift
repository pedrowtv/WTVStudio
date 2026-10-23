import AVFoundation
import CoreMedia
import Foundation
import WTVAudio
import WTVProtocol
import WTVVideo

/// Ficheiro de vídeo/áudio via AVAssetReader (descodificação por hardware, saída 420v com IOSurface).
/// Uma thread entrega frames de vídeo à hora certa (tempo de media → host time); outra enche o anel de áudio.
public final class MediaInput: InputSource, @unchecked Sendable {
    public let id: InputId
    private let ctx: InputContext
    private let url: URL
    private var speed: Double
    private let asset: AVURLAsset
    private var duration: Double = 0
    private var hasVideo = false
    private var hasAudio = false
    private var videoSize = (0, 0)
    private var nominalFPS: Double = 0

    private var lock = os_unfair_lock()
    private var state = "stopped"
    private var loop = false
    private var inSeconds: Double = 0
    private var outSeconds: Double?
    private var positionSeconds: Double = 0   // posição actual (actualizada pela thread de vídeo)
    private var generation = 0                // invalida threads antigas em seek/stop
    private var ring: AudioRing?
    private var lastFrameBuffer: CVPixelBuffer?

    public init(id: InputId, ctx: InputContext, config: JSONValue) throws {
        guard let path = config["path"]?.stringValue, !path.isEmpty else { throw InputError.failed("path em falta") }
        self.id = id
        self.ctx = ctx
        url = URL(fileURLWithPath: path)
        speed = config["speed"]?.doubleValue ?? 1
        guard FileManager.default.fileExists(atPath: url.path) else { throw InputError.notFound(path) }
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    }

    public func start() {
        ctx.report(id, .starting, nil, nil)
        Task { [self] in
            do {
                let dur = try await asset.load(.duration)
                duration = CMTimeGetSeconds(dur)
                let vTracks = try await asset.loadTracks(withMediaType: .video)
                let aTracks = try await asset.loadTracks(withMediaType: .audio)
                hasVideo = !vTracks.isEmpty
                hasAudio = !aTracks.isEmpty
                if let v = vTracks.first {
                    let size = try await v.load(.naturalSize)
                    nominalFPS = Double(try await v.load(.nominalFrameRate))
                    videoSize = (Int(size.width), Int(size.height))
                }
                if hasAudio { ring = ctx.mixer?.ring(for: id) }
                ctx.report(id, .live, hasVideo ? VideoFormat(width: videoSize.0, height: videoSize.1, fps: nominalFPS, pixelFormat: "nv12") : nil, nil)
                reportTransport()
                // Primeiro frame parado para o operador ver a fonte (como no vMix)
                try prerollFirstFrame()
            } catch {
                ctx.report(id, .error, nil, "MEDIA_OPEN: \(error)")
            }
        }
    }

    public func stop() {
        os_unfair_lock_lock(&lock); generation += 1; state = "stopped"; os_unfair_lock_unlock(&lock)
        ring?.clear()
        ctx.mixer?.removeRing(for: id)
        ctx.frames.remove(id)
    }

    public func update(config: JSONValue) {
        if let s = config["speed"]?.doubleValue, s > 0 { speed = s }
    }

    public func handle(command: String, params: JSONValue) throws {
        switch command {
        case "media.play": play(from: nil)
        case "media.pause": pause()
        case "media.stop":
            pause()
            os_unfair_lock_lock(&lock); positionSeconds = inSeconds; state = "stopped"; os_unfair_lock_unlock(&lock)
            try? prerollFirstFrame()
            reportTransport()
        case "media.seek":
            let t = max(0, min(duration, params["seconds"]?.doubleValue ?? 0))
            os_unfair_lock_lock(&lock); let playing = state == "playing"; os_unfair_lock_unlock(&lock)
            if playing { play(from: t) } else {
                os_unfair_lock_lock(&lock); positionSeconds = t; os_unfair_lock_unlock(&lock)
                try? prerollFirstFrame()
                reportTransport()
            }
        case "media.setLoop":
            os_unfair_lock_lock(&lock)
            loop = params["loop"]?.boolValue ?? loop
            inSeconds = params["inSeconds"]?.doubleValue ?? inSeconds
            outSeconds = params["outSeconds"]?.doubleValue ?? outSeconds
            os_unfair_lock_unlock(&lock)
            reportTransport()
        default: break
        }
    }

    // MARK: - Transporte

    private func reportTransport() {
        os_unfair_lock_lock(&lock)
        var t = MediaTransport(durationSeconds: duration, positionSeconds: positionSeconds, state: state, loop: loop)
        t.inSeconds = inSeconds; t.outSeconds = outSeconds
        os_unfair_lock_unlock(&lock)
        ctx.reportMedia(id, t)
    }

    private func makeReader(from seconds: Double) throws -> (AVAssetReader, AVAssetReaderTrackOutput?, AVAssetReaderTrackOutput?) {
        let reader = try AVAssetReader(asset: asset)
        let end = outSeconds.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .positiveInfinity
        reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 600), end: end)
        var vOut: AVAssetReaderTrackOutput?
        var aOut: AVAssetReaderTrackOutput?
        if let v = asset.tracks(withMediaType: .video).first {
            let o = AVAssetReaderTrackOutput(track: v, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
            o.alwaysCopiesSampleData = false
            if reader.canAdd(o) { reader.add(o); vOut = o }
        }
        if let a = asset.tracks(withMediaType: .audio) .first {
            let o = AVAssetReaderTrackOutput(track: a, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: AudioMixer.sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            o.alwaysCopiesSampleData = false
            if reader.canAdd(o) { reader.add(o); aOut = o }
        }
        guard reader.startReading() else { throw InputError.failed("AVAssetReader: \(reader.error?.localizedDescription ?? "?")") }
        return (reader, vOut, aOut)
    }

    /// Mostra o frame na posição actual sem reproduzir.
    private func prerollFirstFrame() throws {
        guard hasVideo else { return }
        os_unfair_lock_lock(&lock); let pos = positionSeconds; os_unfair_lock_unlock(&lock)
        let (reader, vOut, _) = try makeReader(from: pos)
        defer { reader.cancelReading() }
        if let sb = vOut?.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) {
            lastFrameBuffer = pb
            ctx.push(pb, hostTimeNanos: HostClock.nowNanos())
        }
    }

    private func pause() {
        os_unfair_lock_lock(&lock)
        generation += 1
        if state == "playing" { state = "paused" }
        os_unfair_lock_unlock(&lock)
        ring?.clear()
        reportTransport()
    }

    private func play(from seconds: Double?) {
        os_unfair_lock_lock(&lock)
        generation += 1
        let gen = generation
        if let seconds { positionSeconds = seconds }
        if positionSeconds >= duration - 0.05 { positionSeconds = inSeconds }
        let startPos = positionSeconds
        state = "playing"
        let spd = speed
        os_unfair_lock_unlock(&lock)
        ring?.clear()
        reportTransport()

        let t = Thread { [self] in self.playLoop(from: startPos, generation: gen, speed: spd) }
        t.name = "wtv.media.\(id)"
        t.qualityOfService = .userInteractive
        t.start()
    }

    private func isCurrent(_ gen: Int) -> Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return generation == gen
    }

    private func playLoop(from startSeconds: Double, generation gen: Int, speed: Double) {
        var start = startSeconds
        while isCurrent(gen) {
            let reader: AVAssetReader
            let vOut: AVAssetReaderTrackOutput?
            let aOut: AVAssetReaderTrackOutput?
            do { (reader, vOut, aOut) = try makeReader(from: start) } catch {
                ctx.report(id, .error, nil, "MEDIA_READ: \(error)"); return
            }
            let hostStart = HostClock.nowNanos()
            let mediaStart = start
            // Thread de áudio: enche o anel à frente (até ~1 s), bloqueando quando cheio.
            let audioThread = Thread { [self] in
                guard let aOut, let ring else { return }
                while isCurrent(gen), reader.status == .reading, let sb = aOut.copyNextSampleBuffer() {
                    guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                    var len = 0; var ptr: UnsafeMutablePointer<CChar>?
                    guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr, let ptr else { continue }
                    let frames = len / 8
                    var written = 0
                    ptr.withMemoryRebound(to: Float.self, capacity: frames * 2) { fp in
                        while written < frames, isCurrent(gen) {
                            let n = ring.write(fp + written * 2, frames: frames - written)
                            written += n
                            if n == 0 { usleep(5000) }
                        }
                    }
                }
            }
            audioThread.name = "wtv.media.audio.\(id)"
            audioThread.qualityOfService = .userInteractive
            audioThread.start()

            var reachedEnd = true
            var lastReport = HostClock.nowNanos()
            if let vOut {
                while isCurrent(gen), let sb = vOut.copyNextSampleBuffer() {
                    let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
                    let target = hostStart &+ UInt64(max(0, (pts - mediaStart) / speed) * 1e9)
                    let now = HostClock.nowNanos()
                    if target > now { usleep(UInt32(min((target - now) / 1000, 500_000))) }
                    guard isCurrent(gen) else { reachedEnd = false; break }
                    if let pb = CMSampleBufferGetImageBuffer(sb) {
                        lastFrameBuffer = pb
                        ctx.push(pb, hostTimeNanos: target)
                    }
                    os_unfair_lock_lock(&lock); positionSeconds = pts; os_unfair_lock_unlock(&lock)
                    if HostClock.nowNanos() - lastReport > 500_000_000 { lastReport = HostClock.nowNanos(); reportTransport() }
                }
            } else if aOut != nil {
                // Só áudio: espera pelo fim do anel
                while isCurrent(gen), reader.status == .reading { usleep(50_000) }
                reachedEnd = isCurrent(gen)
            }
            // deixa o áudio escoar do anel antes de reiniciar/parar
            if reachedEnd, isCurrent(gen), let ring { while ring.availableFrames > 0 && isCurrent(gen) { usleep(5000) } }
            reader.cancelReading()
            guard reachedEnd, isCurrent(gen) else { return }
            os_unfair_lock_lock(&lock); let shouldLoop = loop; let inPos = inSeconds; os_unfair_lock_unlock(&lock)
            if shouldLoop {
                start = inPos
                continue
            }
            os_unfair_lock_lock(&lock); state = "stopped"; positionSeconds = inPos; generation += 1; os_unfair_lock_unlock(&lock)
            reportTransport()
            return
        }
    }

    public var currentPosition: Double {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return positionSeconds
    }
}
