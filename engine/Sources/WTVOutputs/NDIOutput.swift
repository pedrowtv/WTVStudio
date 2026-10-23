import CNDI
import CoreVideo
import Foundation
import Logging
import WTVAudio

/// Runtime NDI carregado dinamicamente (D17). Um por processo.
public final class NDIRuntime: @unchecked Sendable {
    public static let shared = NDIRuntime()
    private var api = cndi_api_t()
    public private(set) var loaded = false
    public private(set) var path = ""
    public private(set) var version = ""
    public private(set) var error = ""
    private let log = Logger(label: "wtv.ndi")

    private init() {}

    /// Tenta carregar; idempotente. Devolve true se o NDI estiver disponível.
    @discardableResult
    public func load(overridePath: String? = nil) -> Bool {
        if loaded { return true }
        var pathBuf = [CChar](repeating: 0, count: 1024)
        var errBuf = [CChar](repeating: 0, count: 512)
        let rc = cndi_load(&api, overridePath, &pathBuf, Int32(pathBuf.count), &errBuf, Int32(errBuf.count))
        guard rc == 0 else {
            error = String(cString: errBuf)
            log.info("NDI indisponível: \(error)")
            return false
        }
        guard api.initialize() else { error = "NDIlib_initialize falhou"; return false }
        path = String(cString: pathBuf)
        version = api.version().map { String(cString: $0) } ?? "?"
        loaded = true
        log.info("NDI \(version) em \(path)")
        return true
    }

    public var table: cndi_api_t { api }
}

/// Saída NDI do Program: BGRA directamente da IOSurface (um memcpy dentro da libndi) + áudio float planar.
public final class NDIOutput: @unchecked Sendable {
    public let name: String
    private var instance: cndi_send_instance_t?
    private let api: cndi_api_t
    private var frameRate: (Int32, Int32)
    private var audioScratch = [Float](repeating: 0, count: 4096 * 2)
    private var sentFrames = 0
    private let log = Logger(label: "wtv.ndi")

    public init?(name: String, fps: Double) {
        guard NDIRuntime.shared.load() else { return nil }
        api = NDIRuntime.shared.table
        self.name = name
        frameRate = NDIOutput.rational(fps)
        var create = cndi_send_create_t(p_ndi_name: nil, p_groups: nil, clock_video: false, clock_audio: false)
        let inst: cndi_send_instance_t? = name.withCString { cname in
            create.p_ndi_name = cname
            return api.send_create(&create)
        }
        guard let inst else { log.error("NDIlib_send_create falhou"); return nil }
        instance = inst
    }

    deinit { if let instance { api.send_destroy(instance) } }

    static func rational(_ fps: Double) -> (Int32, Int32) {
        switch fps {
        case 29.97: return (30000, 1001)
        case 59.94: return (60000, 1001)
        default: return (Int32(fps.rounded()), 1)
        }
    }

    public func setFrameRate(_ fps: Double) { frameRate = NDIOutput.rational(fps) }

    /// Chamado pela thread de vídeo com o Program BGRA. A libndi copia os dados antes de devolver.
    public func send(video buffer: CVPixelBuffer, hostTimeNanos: UInt64) {
        guard let instance else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        var frame = cndi_video_frame_v2_t()
        frame.xres = Int32(CVPixelBufferGetWidth(buffer))
        frame.yres = Int32(CVPixelBufferGetHeight(buffer))
        frame.FourCC = CNDI_FOURCC_BGRA
        frame.frame_format_type = CNDI_FRAME_PROGRESSIVE
        frame.frame_rate_N = frameRate.0
        frame.frame_rate_D = frameRate.1
        frame.picture_aspect_ratio = Float(frame.xres) / Float(frame.yres)
        frame.timecode = Int64.max
        frame.p_data = base.assumingMemoryBound(to: UInt8.self)
        frame.line_stride_in_bytes = Int32(CVPixelBufferGetBytesPerRow(buffer))
        frame.p_metadata = nil
        frame.timestamp = Int64(hostTimeNanos / 100)
        if sentFrames == 0 {
            let p = base.assumingMemoryBound(to: UInt8.self) + 100 * CVPixelBufferGetBytesPerRow(buffer) + 100 * 4
            log.info("NDI envio 1.º frame: \(frame.xres)x\(frame.yres) stride \(frame.line_stride_in_bytes) píxel(100,100) BGRA=\(p[0]),\(p[1]),\(p[2]),\(p[3])")
        }
        sentFrames += 1
        api.send_send_video_v2(instance, &frame)
    }

    /// PCM intercalado estéreo 48 kHz → planar para a NDI.
    public func send(audioInterleaved samples: UnsafePointer<Float>, frames: Int, hostTimeNanos: UInt64) {
        guard let instance, frames > 0 else { return }
        if audioScratch.count < frames * 2 { audioScratch = [Float](repeating: 0, count: frames * 2) }
        for i in 0..<frames {
            audioScratch[i] = samples[i * 2]
            audioScratch[frames + i] = samples[i * 2 + 1]
        }
        audioScratch.withUnsafeMutableBufferPointer { p in
            var frame = cndi_audio_frame_v3_t()
            frame.sample_rate = Int32(AudioMixer.sampleRate)
            frame.no_channels = 2
            frame.no_samples = Int32(frames)
            frame.timecode = Int64.max
            frame.FourCC = CNDI_FOURCC_FLTP
            frame.p_data = p.baseAddress
            frame.channel_stride_in_bytes = Int32(frames * 4)
            frame.p_metadata = nil
            frame.timestamp = Int64(hostTimeNanos / 100)
            api.send_send_audio_v3(instance, &frame)
        }
    }

    public var connections: Int {
        guard let instance else { return 0 }
        return Int(api.send_get_no_connections(instance, 0))
    }
}
