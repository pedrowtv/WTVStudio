import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import libsrt
import Logging
import VideoToolbox
import WTVAudio
import WTVProtocol
import WTVVideo

/// Fonte SRT (caller ou listener) feita de raiz: socket libsrt → MPEG-TS → H.264/HEVC (VideoToolbox) e AAC (AudioConverter).
/// O caminho de recepção do HaishinKit depende de um relógio de reprodução que não avança no macOS sem leitor de áudio,
/// por isso este módulo é o "plano B" previsto em docs/ARQUITECTURA.md.
public final class SRTInput: InputSource, @unchecked Sendable {
    public let id: InputId
    private let ctx: InputContext
    private let host: String
    private let port: UInt16
    private let listener: Bool
    private let latencyMs: Int32
    private let passphrase: String?
    private let streamId: String?
    private var running = false
    private var thread: Thread?
    private var socket: SRTSOCKET = SRT_INVALID_SOCK
    private var listenSocket: SRTSOCKET = SRT_INVALID_SOCK
    private let demuxer = TSDemuxer()
    private var video: VideoESDecoder?
    private var audio: AACESDecoder?
    private var ring: AudioRing?
    private var reported: InputStatus = .starting
    private var ptsAnchor: (pts: Int64, host: UInt64)?
    private let log = Logger(label: "wtv.srt.recv")
    nonisolated(unsafe) private static var started = false

    public init(id: InputId, ctx: InputContext, config: JSONValue) throws {
        guard let raw = config["url"]?.stringValue, let comps = URLComponents(string: raw), comps.scheme == "srt" else { throw InputError.failed("url srt:// em falta") }
        self.id = id
        self.ctx = ctx
        let q = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        host = comps.host ?? ""
        port = UInt16(comps.port ?? 9000)
        let mode = config["mode"]?.stringValue ?? q["mode"] ?? (host.isEmpty ? "listener" : "caller")
        listener = mode == "listener"
        latencyMs = Int32(config["latencyMs"]?.intValue ?? Int(q["latency"] ?? "") ?? 120)
        passphrase = q["passphrase"] ?? config["passphrase"]?.stringValue
        streamId = q["streamid"] ?? config["streamId"]?.stringValue
    }

    public func start() {
        ctx.report(id, .starting, nil, nil)
        running = true
        ring = ctx.mixer?.ring(for: id)
        let t = Thread { [self] in self.loop() }
        t.name = "wtv.srt.\(id)"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    public func stop() {
        running = false
        if socket != SRT_INVALID_SOCK { srt_close(socket) }
        if listenSocket != SRT_INVALID_SOCK { srt_close(listenSocket) }
        ctx.mixer?.removeRing(for: id)
        ctx.frames.remove(id)
        video?.invalidate()
    }

    private func setOpt<T>(_ s: SRTSOCKET, _ opt: SRT_SOCKOPT, _ value: T) {
        var v = value
        _ = withUnsafePointer(to: &v) { srt_setsockflag(s, opt, $0, Int32(MemoryLayout<T>.size)) }
    }

    private func setOpt(_ s: SRTSOCKET, _ opt: SRT_SOCKOPT, string: String) {
        _ = string.withCString { srt_setsockflag(s, opt, $0, Int32(strlen($0))) }
    }

    private func configure(_ s: SRTSOCKET) {
        setOpt(s, SRTO_TRANSTYPE, SRTT_LIVE)
        setOpt(s, SRTO_LATENCY, latencyMs)
        setOpt(s, SRTO_RCVTIMEO, Int32(1000))
        if let passphrase, !passphrase.isEmpty { setOpt(s, SRTO_PASSPHRASE, string: passphrase) }
        if let streamId, !streamId.isEmpty { setOpt(s, SRTO_STREAMID, string: streamId) }
    }

    private func makeAddr() -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        if listener || host.isEmpty {
            addr.sin_addr.s_addr = INADDR_ANY
        } else {
            var resolved = inet_addr(host)
            if resolved == INADDR_NONE, let h = gethostbyname(host), let list = h.pointee.h_addr_list, let first = list[0] {
                memcpy(&resolved, first, MemoryLayout<in_addr_t>.size)
            }
            addr.sin_addr.s_addr = resolved
        }
        return addr
    }

    private func loop() {
        if !SRTInput.started { srt_startup(); SRTInput.started = true }
        var attempt = 0
        while running {
            if connectOnce() {
                attempt = 0
                receiveLoop()
            } else {
                attempt += 1
            }
            if socket != SRT_INVALID_SOCK { srt_close(socket); socket = SRT_INVALID_SOCK }
            if listenSocket != SRT_INVALID_SOCK { srt_close(listenSocket); listenSocket = SRT_INVALID_SOCK }
            guard running else { return }
            if reported != .noSignal { reported = .noSignal; ctx.report(id, .noSignal, nil, "SRT_DISCONNECTED") }
            Thread.sleep(forTimeInterval: min(5, 0.5 * pow(2, Double(min(attempt, 4)))))
        }
    }

    private func connectOnce() -> Bool {
        var addr = makeAddr()
        let len = Int32(MemoryLayout<sockaddr_in>.size)
        if listener {
            let ls = srt_create_socket()
            guard ls != SRT_INVALID_SOCK else { return false }
            configure(ls)
            let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { srt_bind(ls, $0, len) } }
            guard bound != SRT_ERROR, srt_listen(ls, 1) != SRT_ERROR else {
                log.warning("SRT listen :\(port): \(String(cString: srt_getlasterror_str()))")
                srt_close(ls); return false
            }
            listenSocket = ls
            log.info("SRT à escuta em :\(port) (latência \(latencyMs) ms)")
            let s = srt_accept(ls, nil, nil)
            guard running, s != SRT_INVALID_SOCK else { return false }
            socket = s
            srt_close(ls); listenSocket = SRT_INVALID_SOCK
            log.info("SRT: emissor ligado")
            return true
        } else {
            let s = srt_create_socket()
            guard s != SRT_INVALID_SOCK else { return false }
            configure(s)
            let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { srt_connect(s, $0, len) } }
            guard rc != SRT_ERROR else {
                log.warning("SRT connect \(host):\(port): \(String(cString: srt_getlasterror_str()))")
                srt_close(s); return false
            }
            socket = s
            log.info("SRT ligado a \(host):\(port)")
            return true
        }
    }

    private func receiveLoop() {
        var buffer = [CChar](repeating: 0, count: 1500)
        demuxer.reset()
        video = nil
        audio = nil
        ptsAnchor = nil
        var idleMs = 0
        while running {
            let n = buffer.withUnsafeMutableBufferPointer { srt_recvmsg(socket, $0.baseAddress, Int32($0.count)) }
            if n == SRT_ERROR {
                let state = srt_getsockstate(socket)
                if state == SRTS_BROKEN || state == SRTS_CLOSED || state == SRTS_NONEXIST { return }
                idleMs += 1000
                if idleMs >= 3000, reported != .noSignal { reported = .noSignal; ctx.report(id, .noSignal, nil, "SRT_NO_DATA") }
                continue
            }
            idleMs = 0
            buffer.withUnsafeBufferPointer { p in
                p.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: Int(n)) { demuxer.feed($0, count: Int(n), sink: self.handlePES) }
            }
        }
    }

    private func hostTime(forPTS pts: Int64) -> UInt64 {
        let now = HostClock.nowNanos()
        if ptsAnchor == nil { ptsAnchor = (pts, now) }
        guard let a = ptsAnchor else { return now }
        let delta = Double(pts - a.pts) / 90_000.0
        if abs(Double(Int64(now) - Int64(a.host)) / 1e9 - delta) > 2 { ptsAnchor = (pts, now); return now }
        return a.host &+ UInt64(max(0, delta) * 1e9)
    }

    private func handlePES(_ pes: TSDemuxer.PES) {
        switch pes.streamType {
        case 0x1B, 0x24:
            if video == nil {
                video = VideoESDecoder(hevc: pes.streamType == 0x24) { [weak self] pb, pts in
                    guard let self else { return }
                    self.ctx.push(pb, hostTimeNanos: self.hostTime(forPTS: pts))
                    if self.reported != .live {
                        self.reported = .live
                        self.ctx.report(self.id, .live, VideoFormat(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), fps: 0, pixelFormat: "nv12"), nil)
                    }
                }
            }
            video?.feed(annexB: pes.data, pts: pes.pts)
        case 0x0F:
            if audio == nil { audio = AACESDecoder { [weak self] samples, frames in self?.ring?.write(samples, frames: frames) } }
            audio?.feed(adts: pes.data)
        default:
            break
        }
    }
}

// MARK: - MPEG-TS

/// Desmultiplexador MPEG-TS mínimo: PAT → PMT → PES por PID (vídeo e áudio).
final class TSDemuxer {
    struct PES { let pid: UInt16; let streamType: UInt8; let pts: Int64; let dts: Int64; let data: Data }

    private var pmtPID: UInt16?
    private var streams: [UInt16: UInt8] = [:]
    private var assembling: [UInt16: Data] = [:]
    private var pending = Data()

    func reset() { pmtPID = nil; streams = [:]; assembling = [:]; pending.removeAll() }

    func feed(_ bytes: UnsafePointer<UInt8>, count: Int, sink: (PES) -> Void) {
        pending.append(bytes, count: count)
        while pending.count >= 188 {
            guard pending[pending.startIndex] == 0x47 else { pending.removeFirst(1); continue }
            let packet = [UInt8](pending.subdata(in: pending.startIndex..<pending.startIndex + 188))
            pending.removeFirst(188)
            parse(packet, sink: sink)
        }
    }

    private func parse(_ b: [UInt8], sink: (PES) -> Void) {
        let pusi = (b[1] & 0x40) != 0
        let pid = UInt16(b[1] & 0x1F) << 8 | UInt16(b[2])
        let afc = (b[3] >> 4) & 0x3
        var offset = 4
        if afc == 2 { return }
        if afc == 3 { offset += 1 + Int(b[4]) }
        guard offset < 188 else { return }
        if pid == 0 { parsePAT(b, offset: offset, pusi: pusi); return }
        if let pmt = pmtPID, pid == pmt { parsePMT(b, offset: offset, pusi: pusi); return }
        guard let type = streams[pid] else { return }
        if pusi {
            if let prev = assembling[pid] { emit(pid: pid, type: type, pes: prev, sink: sink) }
            assembling[pid] = Data(b[offset...])
        } else if assembling[pid] != nil {
            assembling[pid]!.append(contentsOf: b[offset...])
        }
    }

    private func parsePAT(_ b: [UInt8], offset: Int, pusi: Bool) {
        var i = offset
        if pusi { i += 1 + Int(b[i]) }
        guard i + 8 < 188 else { return }
        let sectionLength = Int(b[i + 1] & 0x0F) << 8 | Int(b[i + 2])
        var j = i + 8
        let end = min(188, i + 3 + sectionLength - 4)
        while j + 4 <= end {
            let program = Int(b[j]) << 8 | Int(b[j + 1])
            let pidv = UInt16(b[j + 2] & 0x1F) << 8 | UInt16(b[j + 3])
            if program != 0 { pmtPID = pidv; break }
            j += 4
        }
    }

    private func parsePMT(_ b: [UInt8], offset: Int, pusi: Bool) {
        var i = offset
        if pusi { i += 1 + Int(b[i]) }
        guard i + 12 < 188 else { return }
        let sectionLength = Int(b[i + 1] & 0x0F) << 8 | Int(b[i + 2])
        let infoLength = Int(b[i + 10] & 0x0F) << 8 | Int(b[i + 11])
        var j = i + 12 + infoLength
        let end = min(188, i + 3 + sectionLength - 4)
        var found: [UInt16: UInt8] = [:]
        while j + 5 <= end {
            let type = b[j]
            let pidv = UInt16(b[j + 1] & 0x1F) << 8 | UInt16(b[j + 2])
            let esLen = Int(b[j + 3] & 0x0F) << 8 | Int(b[j + 4])
            found[pidv] = type
            j += 5 + esLen
        }
        if !found.isEmpty { streams = found }
    }

    private func emit(pid: UInt16, type: UInt8, pes: Data, sink: (PES) -> Void) {
        let b = [UInt8](pes)
        guard b.count > 9, b[0] == 0, b[1] == 0, b[2] == 1 else { return }
        let flags = b[7]
        let headerLen = Int(b[8])
        var pts: Int64 = -1, dts: Int64 = -1
        func ts(_ o: Int) -> Int64 {
            Int64(b[o] & 0x0E) << 29 | Int64(b[o + 1]) << 22 | Int64(b[o + 2] & 0xFE) << 14 | Int64(b[o + 3]) << 7 | Int64(b[o + 4] >> 1)
        }
        if flags & 0x80 != 0, b.count >= 14 { pts = ts(9) }
        if flags & 0x40 != 0, b.count >= 19 { dts = ts(14) }
        let start = 9 + headerLen
        guard start < b.count else { return }
        sink(PES(pid: pid, streamType: type, pts: pts, dts: dts < 0 ? pts : dts, data: Data(b[start...])))
    }
}

// MARK: - Vídeo (Annex-B → VideoToolbox)

final class VideoESDecoder {
    private let hevc: Bool
    private var sps: Data?, pps: Data?, vps: Data?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private let onFrame: (CVPixelBuffer, Int64) -> Void
    private let log = Logger(label: "wtv.srt.video")

    init(hevc: Bool, onFrame: @escaping (CVPixelBuffer, Int64) -> Void) {
        self.hevc = hevc
        self.onFrame = onFrame
    }

    func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    private func nalType(_ nal: Data) -> Int {
        guard let first = nal.first else { return -1 }
        return hevc ? Int((first >> 1) & 0x3F) : Int(first & 0x1F)
    }

    func feed(annexB data: Data, pts: Int64) {
        let nals = splitAnnexB(data)
        var au = Data()
        var paramsChanged = false
        var hasVCL = false
        for nal in nals {
            let t = nalType(nal)
            if hevc {
                switch t {
                case 32: vps = nal; paramsChanged = true; continue
                case 33: sps = nal; paramsChanged = true; continue
                case 34: pps = nal; paramsChanged = true; continue
                case 35, 39, 40: continue
                default: if t <= 31 { hasVCL = true }
                }
            } else {
                switch t {
                case 7: sps = nal; paramsChanged = true; continue
                case 8: pps = nal; paramsChanged = true; continue
                case 9, 6: continue
                default: if t == 1 || t == 5 { hasVCL = true }
                }
            }
            var len = UInt32(nal.count).bigEndian
            au.append(Data(bytes: &len, count: 4))
            au.append(nal)
        }
        if paramsChanged || format == nil { rebuildFormat() }
        guard hasVCL, let format, !au.isEmpty else { return }
        if session == nil { makeSession(format) }
        guard let session else { return }
        var block: CMBlockBuffer?
        let count = au.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: count, flags: 0, blockBufferOut: &block) == noErr, let block else { return }
        au.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(pts), timescale: 90_000), decodeTimeStamp: .invalid)
        var size = count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return }
        let ptsCopy = pts
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard let self, status == noErr, let image else { return }
            self.onFrame(image, ptsCopy)
        }
    }

    private func rebuildFormat() {
        guard let sps, let pps else { return }
        var sets: [[UInt8]] = hevc ? [[UInt8](vps ?? Data()), [UInt8](sps), [UInt8](pps)] : [[UInt8](sps), [UInt8](pps)]
        if hevc && vps == nil { return }
        var desc: CMVideoFormatDescription?
        let sizes = sets.map(\.count)
        let st: OSStatus = sets[0].withUnsafeBufferPointer { p0 in
            sets[1].withUnsafeBufferPointer { p1 in
                if hevc {
                    return sets[2].withUnsafeBufferPointer { p2 in
                        var ptrs: [UnsafePointer<UInt8>] = [p0.baseAddress!, p1.baseAddress!, p2.baseAddress!]
                        return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: 3, parameterSetPointers: &ptrs, parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
                    }
                }
                var ptrs: [UnsafePointer<UInt8>] = [p0.baseAddress!, p1.baseAddress!]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: &ptrs, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
            }
        }
        _ = sets
        guard st == noErr, let desc else { log.warning("parameter sets inválidos (\(st))"); return }
        if let old = format, CMFormatDescriptionEqual(old, otherFormatDescription: desc) { return }
        format = desc
        invalidate()
    }

    private func makeSession(_ format: CMVideoFormatDescription) {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        guard st == noErr, let s else { log.warning("VTDecompressionSession: \(st)"); return }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
    }

    private func splitAnnexB(_ d: Data) -> [Data] {
        let b = [UInt8](d)
        var out: [Data] = []
        var i = 0, start = -1
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start, b[end - 1] == 0 { end -= 1 }
                    if end > start { out.append(Data(b[start..<end])) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < b.count { out.append(Data(b[start...])) }
        return out
    }
}

// MARK: - Áudio (AAC ADTS → PCM float 48 kHz estéreo)

final class AACESDecoder {
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private var key: (Int, Int, Int) = (-1, -1, -1)
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioMixer.sampleRate, channels: 2, interleaved: true)!
    private let onPCM: (UnsafePointer<Float>, Int) -> Void
    private let log = Logger(label: "wtv.srt.audio")
    private static let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    init(onPCM: @escaping (UnsafePointer<Float>, Int) -> Void) { self.onPCM = onPCM }

    func feed(adts data: Data) {
        let b = [UInt8](data)
        var i = 0
        while i + 7 <= b.count {
            guard b[i] == 0xFF, (b[i + 1] & 0xF0) == 0xF0 else { i += 1; continue }
            let protectionAbsent = b[i + 1] & 1
            let profile = Int((b[i + 2] >> 6) & 0x3) + 1
            let srIndex = Int((b[i + 2] >> 2) & 0xF)
            let channels = Int((b[i + 2] & 0x1) << 2 | (b[i + 3] >> 6) & 0x3)
            let frameLen = Int(b[i + 3] & 0x3) << 11 | Int(b[i + 4]) << 3 | Int(b[i + 5] >> 5)
            let headerLen = protectionAbsent == 1 ? 7 : 9
            guard frameLen > headerLen, i + frameLen <= b.count, srIndex < AACESDecoder.rates.count else { break }
            ensureConverter(profile: profile, srIndex: srIndex, channels: channels)
            decode(Array(b[(i + headerLen)..<(i + frameLen)]))
            i += frameLen
        }
    }

    private func ensureConverter(profile: Int, srIndex: Int, channels: Int) {
        guard key != (profile, srIndex, channels) else { return }
        key = (profile, srIndex, channels)
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(AACESDecoder.rates[srIndex]), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: UInt32(profile),
                                               mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(max(1, channels)), mBitsPerChannel: 0, mReserved: 0)
        guard let f = AVAudioFormat(streamDescription: &asbd), let c = AVAudioConverter(from: f, to: outFormat) else { log.warning("conversor AAC indisponível"); return }
        let asc: [UInt8] = [UInt8(profile << 3 | srIndex >> 1), UInt8((srIndex & 1) << 7 | channels << 3)]
        c.magicCookie = Data(asc)
        converter = c
        inFormat = f
    }

    private func decode(_ frame: [UInt8]) {
        guard let converter, let inFormat else { return }
        let inBuf = AVAudioCompressedBuffer(format: inFormat, packetCapacity: 1, maximumPacketSize: max(frame.count, 1536))
        frame.withUnsafeBufferPointer { inBuf.data.copyMemory(from: $0.baseAddress!, byteCount: frame.count) }
        inBuf.byteLength = UInt32(frame.count)
        inBuf.packetCount = 1
        inBuf.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.count))
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 4096) else { return }
        var done = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if done { outStatus.pointee = .noDataNow; return nil }
            done = true; outStatus.pointee = .haveData; return inBuf
        }
        guard status != .error, out.frameLength > 0, let data = out.floatChannelData?[0] else { return }
        onPCM(data, Int(out.frameLength))
    }
}
