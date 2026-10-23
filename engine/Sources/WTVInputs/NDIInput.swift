import CNDI
import CoreVideo
import Foundation
import Logging
import WTVAudio
import WTVOutputs
import WTVProtocol
import WTVVideo

/// Descoberta de fontes NDI na rede (NDIlib_find). Uma instância partilhada; lista refrescada a pedido.
public final class NDIDiscovery: @unchecked Sendable {
    public static let shared = NDIDiscovery()
    private var finder: cndi_find_instance_t?
    private let log = Logger(label: "wtv.ndi.find")

    private init() {}

    /// Devolve as fontes conhecidas (espera até `waitMs` por novas). Vazio se o NDI não estiver disponível.
    public func sources(waitMs: UInt32 = 1500) -> [NdiSource] {
        guard NDIRuntime.shared.load() else { return [] }
        let api = NDIRuntime.shared.table
        if finder == nil {
            var create = cndi_find_create_t(show_local_sources: true, p_groups: nil, p_extra_ips: nil)
            finder = api.find_create_v2(&create)
        }
        guard let finder else { return [] }
        _ = api.find_wait_for_sources(finder, waitMs)
        var count: UInt32 = 0
        guard let list = api.find_get_current_sources(finder, &count) else { return [] }
        return (0..<Int(count)).map { i in
            let src = list[i]
            return NdiSource(name: src.p_ndi_name.map { String(cString: $0) } ?? "?", url: src.p_url_address.map { String(cString: $0) } ?? "")
        }
    }
}

/// Fonte NDI (D17): recebe BGRA já descodificado pela libndi, copia uma vez para um pool de IOSurfaces,
/// e entrega o áudio float planar ao anel do mixer. Modo "low bandwidth" quando a fonte não está em Program/Preview.
public final class NDIInput: InputSource, @unchecked Sendable {
    public let id: InputId
    private let ctx: InputContext
    private var sourceName: String
    private var bandwidthLowest: Bool
    private var receiver: cndi_recv_instance_t?
    private var thread: Thread?
    private var running = false
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var ring: AudioRing?
    private var audioScratch = [Float](repeating: 0, count: 8192 * 2)
    private var frames = 0
    private var lastVideoNanos: UInt64 = 0
    private let log = Logger(label: "wtv.ndi.recv")

    public init(id: InputId, ctx: InputContext, config: JSONValue) throws {
        guard let name = config["sourceName"]?.stringValue, !name.isEmpty else { throw InputError.failed("sourceName em falta") }
        guard NDIRuntime.shared.load() else { throw InputError.unsupported("runtime NDI não encontrado") }
        self.id = id
        self.ctx = ctx
        sourceName = name
        bandwidthLowest = config["bandwidth"]?.stringValue == "lowest"
    }

    public func start() {
        ctx.report(id, .starting, nil, nil)
        running = true
        ring = ctx.mixer?.ring(for: id)
        let t = Thread { [self] in self.loop() }
        t.name = "wtv.ndi.\(id)"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    public func stop() {
        running = false
        ctx.mixer?.removeRing(for: id)
        ctx.frames.remove(id)
    }

    public func update(config: JSONValue) {
        if let b = config["bandwidth"]?.stringValue { bandwidthLowest = b == "lowest" }
        if let n = config["sourceName"]?.stringValue, n != sourceName {
            sourceName = n
            stop()
            start()
        }
    }

    private func connect(api: cndi_api_t) -> cndi_recv_instance_t? {
        var inst: cndi_recv_instance_t?
        sourceName.withCString { cname in
            "WTV Studio".withCString { rname in
                var create = cndi_recv_create_v3_t(
                    source_to_connect_to: cndi_source_t(p_ndi_name: cname, p_url_address: nil),
                    color_format: CNDI_RECV_COLOR_BGRX_BGRA,
                    bandwidth: bandwidthLowest ? CNDI_RECV_BANDWIDTH_LOWEST : CNDI_RECV_BANDWIDTH_HIGHEST,
                    allow_video_fields: false,
                    p_ndi_recv_name: rname)
                inst = api.recv_create_v3(&create)
            }
        }
        return inst
    }

    private func loop() {
        let api = NDIRuntime.shared.table
        guard let recv = connect(api: api) else {
            ctx.report(id, .error, nil, "NDI_RECV_CREATE"); return
        }
        receiver = recv
        defer { api.recv_destroy(recv); receiver = nil }
        var video = cndi_video_frame_v2_t()
        var audio = cndi_audio_frame_v3_t()
        var meta = cndi_metadata_frame_t()
        var lastSignal = HostClock.nowNanos()
        var reported: InputStatus = .starting
        while running {
            let type = api.recv_capture_v3(recv, &video, &audio, &meta, 100)
            switch type {
            case CNDI_FRAME_TYPE_VIDEO:
                defer { api.recv_free_video_v2(recv, &video) }
                deliver(video: video)
                lastSignal = HostClock.nowNanos()
                if reported != .live { reported = .live; ctx.report(id, .live, VideoFormat(width: Int(video.xres), height: Int(video.yres), fps: Double(video.frame_rate_N) / Double(max(1, video.frame_rate_D)), pixelFormat: "bgra"), nil) }
            case CNDI_FRAME_TYPE_AUDIO:
                defer { api.recv_free_audio_v3(recv, &audio) }
                deliver(audio: audio)
            case CNDI_FRAME_TYPE_METADATA:
                api.recv_free_metadata(recv, &meta)
            case CNDI_FRAME_TYPE_ERROR:
                if reported != .error { reported = .error; ctx.report(id, .error, nil, "NDI_RECV_ERROR") }
            default:
                if HostClock.nowNanos() - lastSignal > 3_000_000_000, reported != .noSignal {
                    reported = .noSignal
                    ctx.report(id, .noSignal, nil, "NDI_NO_SIGNAL")
                }
            }
        }
    }

    private func deliver(video f: cndi_video_frame_v2_t) {
        guard let src = f.p_data else { return }
        if f.FourCC != CNDI_FOURCC_BGRA && f.FourCC != CNDI_FOURCC_BGRX {
            if frames == 0 { log.warning("NDI: formato inesperado \(String(format: "%08x", f.FourCC)); pedido BGRA") }
            return
        }
        let w = Int(f.xres), h = Int(f.yres)
        if frames == 0 {
            let cc = [UInt8(f.FourCC & 0xff), UInt8((f.FourCC >> 8) & 0xff), UInt8((f.FourCC >> 16) & 0xff), UInt8((f.FourCC >> 24) & 0xff)]
            let p = src + 100 * Int(f.line_stride_in_bytes) + 100 * 4
            log.info("NDI 1.º frame: \(String(bytes: cc, encoding: .ascii) ?? "?") \(w)x\(h) stride \(f.line_stride_in_bytes) fps \(f.frame_rate_N)/\(f.frame_rate_D) formato \(f.frame_format_type) píxel(100,100) BGRA=\(p[0]),\(p[1]),\(p[2]),\(p[3])")
        }
        if pool == nil || poolSize != (w, h) {
            pool = try? MetalContext.makePool(width: w, height: h, format: kCVPixelFormatType_32BGRA, count: 4)
            poolSize = (w, h)
        }
        guard let pool, let buffer = try? MetalContext.makeBuffer(from: pool) else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let dst = CVPixelBufferGetBaseAddress(buffer) {
            let dstStride = CVPixelBufferGetBytesPerRow(buffer), srcStride = Int(f.line_stride_in_bytes)
            if dstStride == srcStride {
                memcpy(dst, src, srcStride * h)
            } else {
                for y in 0..<h { memcpy(dst + y * dstStride, src + y * srcStride, min(dstStride, srcStride)) }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        ctx.push(buffer, hostTimeNanos: HostClock.nowNanos(), fullRange: true)
        frames += 1
    }

    private func deliver(audio a: cndi_audio_frame_v3_t) {
        guard let ring, a.FourCC == CNDI_FOURCC_FLTP, let data = a.p_data, a.no_samples > 0 else { return }
        let n = Int(a.no_samples), ch = Int(a.no_channels)
        let strideFloats = Int(a.channel_stride_in_bytes) / 4
        if audioScratch.count < n * 2 { audioScratch = [Float](repeating: 0, count: n * 2) }
        let rate = Double(a.sample_rate)
        if rate != AudioMixer.sampleRate {
            // Reamostragem linear simples (a NDI quase sempre envia 48 kHz; o ASRC real chega na Fase 2)
            let outN = Int(Double(n) * AudioMixer.sampleRate / rate)
            if audioScratch.count < outN * 2 { audioScratch = [Float](repeating: 0, count: outN * 2) }
            for i in 0..<outN {
                let pos = Double(i) * rate / AudioMixer.sampleRate
                let j = min(n - 1, Int(pos)), frac = Float(pos - Double(j)), k = min(n - 1, j + 1)
                let l0 = data[j], l1 = data[k]
                let r0 = ch > 1 ? data[strideFloats + j] : l0, r1 = ch > 1 ? data[strideFloats + k] : l1
                audioScratch[i * 2] = l0 + (l1 - l0) * frac
                audioScratch[i * 2 + 1] = r0 + (r1 - r0) * frac
            }
            audioScratch.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: outN) }
            return
        }
        for i in 0..<n {
            audioScratch[i * 2] = data[i]
            audioScratch[i * 2 + 1] = ch > 1 ? data[strideFloats + i] : data[i]
        }
        audioScratch.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: n) }
    }
}
