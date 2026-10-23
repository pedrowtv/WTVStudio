import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import WTVCore

/// Codificador H.264 de baixa latência para o preview (D13). Um por stream.
public final class PreviewEncoder: @unchecked Sendable {
    public let stream: PreviewFrame.Stream
    private var session: VTCompressionSession?
    private let width: Int
    private let height: Int
    private let fps: Int
    private let bitrate: Int
    private var seq: UInt32 = 0
    private var forceKey = true
    private var lock = os_unfair_lock()
    private let onFrame: (Data) -> Void

    public init(stream: PreviewFrame.Stream, width: Int, height: Int, fps: Int, bitrate: Int, onFrame: @escaping (Data) -> Void) throws {
        self.stream = stream
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.onFrame = onFrame
        try createSession()
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    private func createSession() throws {
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else { throw VideoToolboxError.create(status) }
        func set(_ key: CFString, _ value: CFTypeRef) { VTSessionSetProperty(s, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 2) as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_DataRateLimits, [bitrate / 8 * 2, 1] as CFArray)
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
    }

    /// Pede um keyframe no próximo frame (novo cliente).
    public func requestKeyframe() {
        os_unfair_lock_lock(&lock); forceKey = true; os_unfair_lock_unlock(&lock)
    }

    public func encode(_ buffer: CVPixelBuffer, ptsMicros: UInt64) {
        guard let session else { return }
        os_unfair_lock_lock(&lock)
        let key = forceKey
        forceKey = false
        os_unfair_lock_unlock(&lock)
        let pts = CMTime(value: CMTimeValue(ptsMicros), timescale: 1_000_000)
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: pts, duration: duration,
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self, status == noErr, let sample else { return }
            self.deliver(sample, ptsMicros: ptsMicros)
        }
    }

    private func deliver(_ sample: CMSampleBuffer, ptsMicros: UInt64) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let isKey: Bool = {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
                  let first = attachments.first else { return true }
            return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        }()
        var config: Data?
        if isKey, let desc = CMSampleBufferGetFormatDescription(sample) {
            config = PreviewEncoder.avcC(from: desc)
        }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return }
        let payload = Data(bytes: pointer, count: length) // já em AVCC (prefixo de comprimento de 4 bytes)
        os_unfair_lock_lock(&lock)
        let s = seq
        seq &+= 1
        os_unfair_lock_unlock(&lock)
        let message = PreviewFrame.encode(stream: stream, flags: isKey ? [.keyframe] : [], codec: .avc1, seq: s, ptsMicros: ptsMicros, config: config, payload: payload)
        onFrame(message)
    }

    /// Constrói o registo avcC (ISO 14496-15) a partir dos parameter sets SPS/PPS.
    static func avcC(from desc: CMFormatDescription) -> Data? {
        var count = 0
        var nalLength: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(desc, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                                                                 parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength) == noErr, count >= 2 else { return nil }
        func set(_ i: Int) -> Data? {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(desc, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                                                                     parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr else { return nil }
            return Data(bytes: ptr, count: size)
        }
        guard let sps = set(0), let pps = set(1), sps.count >= 4 else { return nil }
        var out = Data()
        out.append(1)                    // configurationVersion
        out.append(sps[1])               // AVCProfileIndication
        out.append(sps[2])               // profile_compatibility
        out.append(sps[3])               // AVCLevelIndication
        out.append(0xFC | UInt8(nalLength - 1)) // lengthSizeMinusOne
        out.append(0xE0 | 1)             // numOfSequenceParameterSets
        out.append(UInt8(sps.count >> 8)); out.append(UInt8(sps.count & 0xff))
        out.append(sps)
        out.append(1)                    // numOfPictureParameterSets
        out.append(UInt8(pps.count >> 8)); out.append(UInt8(pps.count & 0xff))
        out.append(pps)
        return out
    }
}

public enum VideoToolboxError: Error, CustomStringConvertible {
    case create(OSStatus)
    public var description: String {
        switch self {
        case .create(let s): return "VTCompressionSessionCreate falhou: \(s)"
        }
    }
}

/// Distribui frames codificados pelos clientes de /ws/preview. Um cliente lento perde frames
/// (buffer de 8 mensagens, mantém as mais recentes); nunca bloqueia o codificador.
public final class PreviewHub: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var subscribers: [UUID: (stream: String, cont: AsyncStream<Data>.Continuation)] = [:]
    public var onNewSubscriber: ((String) -> Void)?

    public init() {}

    public func subscribe(stream: String) -> (UUID, AsyncStream<Data>) {
        let id = UUID()
        let s = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(8)) { cont in
            os_unfair_lock_lock(&lock)
            subscribers[id] = (stream, cont)
            os_unfair_lock_unlock(&lock)
        }
        onNewSubscriber?(stream)
        return (id, s)
    }

    public func unsubscribe(_ id: UUID) {
        os_unfair_lock_lock(&lock)
        let entry = subscribers.removeValue(forKey: id)
        os_unfair_lock_unlock(&lock)
        entry?.cont.finish()
    }

    public func publish(stream: String, _ data: Data) {
        os_unfair_lock_lock(&lock)
        let targets = subscribers.values.filter { $0.stream == stream }.map(\.cont)
        os_unfair_lock_unlock(&lock)
        for c in targets { c.yield(data) }
    }

    /// Envia a todos os clientes, independentemente do stream (VU, posições de media).
    public func publishAll(_ data: Data) {
        os_unfair_lock_lock(&lock)
        let targets = subscribers.values.map(\.cont)
        os_unfair_lock_unlock(&lock)
        for c in targets { c.yield(data) }
    }

    public var totalCount: Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return subscribers.count
    }

    public func count(stream: String) -> Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return subscribers.values.filter { $0.stream == stream }.count
    }
}
