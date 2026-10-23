import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import Logging
import WTVAudio
import WTVCore

/// Destino de bitstream comprimido (RTMP, gravador…). Recebe sempre o mesmo H.264/AAC (D11).
public protocol StreamSink: AnyObject, Sendable {
    var sinkId: String { get }
    func sink(video sample: CMSampleBuffer, isKeyframe: Bool)
    func sink(audio sample: CMSampleBuffer, compressed: AVAudioCompressedBuffer, when: AVAudioTime)
}

/// Codificador H.264 do Program (VideoToolbox) + AAC do bus master, com fan-out para N sinks.
/// Começa a entregar a cada sink só a partir de um keyframe, e o áudio só depois do primeiro vídeo.
public final class ProgramEncoder: @unchecked Sendable {
    public struct Profile: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var fps: Int
        public var videoBitrate: Int
        public var audioBitrate: Int
        public var codec: CMVideoCodecType
        public init(width: Int, height: Int, fps: Int, videoBitrate: Int = 6_000_000, audioBitrate: Int = 160_000, codec: CMVideoCodecType = kCMVideoCodecType_H264) {
            self.width = width; self.height = height; self.fps = fps; self.videoBitrate = videoBitrate; self.audioBitrate = audioBitrate; self.codec = codec
        }
    }

    public let profile: Profile
    private var session: VTCompressionSession?
    private var lock = os_unfair_lock()
    private var sinks: [String: (sink: StreamSink, started: Bool)] = [:]
    private var forceKey = true
    private var lastKeyPTS: UInt64 = 0

    // Áudio
    private let inFormat: AVAudioFormat
    private var outFormat: AVAudioFormat?
    private var aacFormatDescription: CMFormatDescription?
    public var audioFormatDescription: CMFormatDescription? { aacFormatDescription }
    private var pendingPCM = [Float]()       // intercalado, à espera de 1024 frames
    private var pcmHostStart: UInt64 = 0     // (já não usado para PTS; mantido para diagnóstico)
    private var audioAnchorHost: UInt64 = 0  // host time do primeiro sample recebido
    private var audioPackets: Int64 = 0      // pacotes AAC emitidos desde a âncora (PTS = âncora + n·1024/48000)
    private var audioStarted = false
    private var firstVideoHost: UInt64 = 0
    private let log = Logger(label: "wtv.encoder")
    private var dbgAppend = 0, dbgPackets = 0, dbgSkipped = 0, dbgFail = 0

    public init(profile: Profile) throws {
        self.profile = profile
        inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioMixer.sampleRate, channels: 2, interleaved: true)!
        try createVideoSession()
        try createAudioConverter()
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    // MARK: - Sinks

    public func add(_ sink: StreamSink) {
        os_unfair_lock_lock(&lock)
        sinks[sink.sinkId] = (sink, false)
        forceKey = true
        os_unfair_lock_unlock(&lock)
    }

    public func remove(_ id: String) {
        os_unfair_lock_lock(&lock); sinks[id] = nil; os_unfair_lock_unlock(&lock)
    }

    public var sinkCount: Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return sinks.count
    }

    // MARK: - Vídeo

    private func createVideoSession() throws {
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(profile.width), height: Int32(profile.height), codecType: profile.codec,
                                            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else { throw VideoToolboxError.create(st) }
        func set(_ k: CFString, _ v: CFTypeRef) { VTSessionSetProperty(s, key: k, value: v) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, profile.codec == kCMVideoCodecType_HEVC ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, profile.videoBitrate as CFNumber)
        set(kVTCompressionPropertyKey_DataRateLimits, [profile.videoBitrate / 8 * 3 / 2, 1] as CFArray)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, profile.fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (profile.fps * 2) as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber)
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
    }

    /// Chamado pela thread de vídeo com o Program em NV12.
    public func encodeVideo(_ buffer: CVPixelBuffer, hostTimeNanos: UInt64) {
        guard let session, sinkCount > 0 else { return }
        os_unfair_lock_lock(&lock)
        let key = forceKey
        forceKey = false
        os_unfair_lock_unlock(&lock)
        let pts = CMTime(value: CMTimeValue(hostTimeNanos / 1000), timescale: 1_000_000)
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: CMTimeScale(profile.fps)),
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self, status == noErr, let sample else { return }
            self.fanOutVideo(sample, hostTimeNanos: hostTimeNanos)
        }
    }

    private func fanOutVideo(_ sample: CMSampleBuffer, hostTimeNanos: UInt64) {
        let isKey: Bool = {
            guard let a = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]], let f = a.first else { return true }
            return !(f[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        }()
        os_unfair_lock_lock(&lock)
        if firstVideoHost == 0 && isKey { firstVideoHost = hostTimeNanos }
        var targets: [StreamSink] = []
        for (id, entry) in sinks {
            if !entry.started {
                guard isKey else { continue }
                sinks[id]?.started = true
            }
            targets.append(entry.sink)
        }
        os_unfair_lock_unlock(&lock)
        for t in targets { t.sink(video: sample, isKeyframe: isKey) }
    }

    // MARK: - Áudio (AAC-LC 48 kHz estéreo) via AVAudioConverter

    private var avConverter: AVAudioConverter?
    private var pcmBuffer: AVAudioPCMBuffer?

    private func createAudioConverter() throws {
        var asbd = AudioStreamBasicDescription(mSampleRate: AudioMixer.sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
                                               mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        guard let out = AVAudioFormat(streamDescription: &asbd), let conv = AVAudioConverter(from: inFormat, to: out) else {
            throw VideoToolboxError.create(-1)
        }
        conv.bitRate = profile.audioBitrate
        avConverter = conv
        outFormat = out
        pcmBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 1024)
        // Pré-aquece com silêncio para obter o magic cookie (AudioSpecificConfig) já no arranque.
        let silence = [Float](repeating: 0, count: 1024 * 2)
        _ = convertPacket(silence)
        let cookie = conv.magicCookie.map { [UInt8]($0) } ?? []
        var desc: CMFormatDescription?
        let st = cookie.withUnsafeBufferPointer { cp -> OSStatus in
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: cookie.count, magicCookie: cookie.isEmpty ? nil : UnsafeRawPointer(cp.baseAddress!),
                                           extensions: nil, formatDescriptionOut: &desc)
        }
        guard st == noErr, let desc else { throw VideoToolboxError.create(st) }
        aacFormatDescription = desc
        pendingPCM.reserveCapacity(1024 * 2 * 4)
    }

    /// Converte 1024 frames PCM intercalados num pacote AAC. nil se o conversor ainda não produziu saída.
    private func convertPacket(_ pcm: [Float]) -> AVAudioCompressedBuffer? {
        guard let conv = avConverter, let outFormat, let pcmBuffer else { return nil }
        pcmBuffer.frameLength = 1024
        pcm.withUnsafeBufferPointer { pcmBuffer.floatChannelData![0].update(from: $0.baseAddress!, count: 1024 * 2) }
        let out = AVAudioCompressedBuffer(format: outFormat, packetCapacity: 1, maximumPacketSize: 1536)
        var done = false
        var error: NSError?
        let status = conv.convert(to: out, error: &error) { _, outStatus in
            if done { outStatus.pointee = .noDataNow; return nil }
            done = true
            outStatus.pointee = .haveData
            return pcmBuffer
        }
        guard status != .error, out.packetCount == 1, out.byteLength > 0 else {
            dbgFail += 1
            if dbgFail < 4 { log.warning("AAC: \(status.rawValue) \(error?.localizedDescription ?? "") bytes \(out.byteLength)") }
            return nil
        }
        return out
    }

    /// Chamado pelo mixer (fora do callback de tempo real) com blocos PCM intercalados estéreo.
    public func appendAudio(_ samples: UnsafePointer<Float>, frames: Int, hostTimeNanos: UInt64) {
        guard sinkCount > 0 else { pendingPCM.removeAll(keepingCapacity: true); return }
        dbgAppend += 1
        if dbgAppend % 500 == 1 { log.debug("áudio: appends \(dbgAppend) pacotes \(dbgPackets) saltados \(dbgSkipped) falhas \(dbgFail)") }
        if audioAnchorHost == 0 { audioAnchorHost = hostTimeNanos; audioPackets = 0 }
        pendingPCM.append(contentsOf: UnsafeBufferPointer(start: samples, count: frames * 2))
        while pendingPCM.count >= 1024 * 2 {
            // PTS contínuo a partir da âncora: nunca depende do instante em que o timer acordou.
            let pts = audioAnchorHost &+ UInt64(Double(audioPackets) * 1024.0 / AudioMixer.sampleRate * 1e9)
            audioPackets += 1
            encodeAACPacket(Array(pendingPCM[0..<(1024 * 2)]), hostTimeNanos: pts)
            pendingPCM.removeFirst(1024 * 2)
        }
    }

    private func encodeAACPacket(_ pcm: [Float], hostTimeNanos: UInt64) {
        guard let aacFormatDescription else { return }
        // só depois do primeiro keyframe de vídeo, para A/V começarem juntos
        os_unfair_lock_lock(&lock); let videoStart = firstVideoHost; os_unfair_lock_unlock(&lock)
        guard videoStart > 0, hostTimeNanos &+ 21_000_000 >= videoStart else { dbgSkipped += 1; return }
        guard let outBuffer = convertPacket(pcm) else { return }
        dbgPackets += 1
        // CMSampleBuffer para o AVAssetWriter
        var block: CMBlockBuffer?
        let len = Int(outBuffer.byteLength)
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: len, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: len, flags: 0, blockBufferOut: &block) == noErr, let block else { return }
        CMBlockBufferReplaceDataBytes(with: outBuffer.data, blockBuffer: block, offsetIntoDestination: 0, dataLength: len)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1024, timescale: CMTimeScale(AudioMixer.sampleRate)),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(hostTimeNanos / 1000), timescale: 1_000_000), decodeTimeStamp: .invalid)
        var sizeArr = [len]
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: aacFormatDescription, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sizeArr, sampleBufferOut: &sample) == noErr, let sample else { return }
        let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: Double(hostTimeNanos) / 1e9))
        os_unfair_lock_lock(&lock)
        let targets = sinks.values.filter(\.started).map(\.sink)
        os_unfair_lock_unlock(&lock)
        for t in targets { t.sink(audio: sample, compressed: outBuffer, when: when) }
    }
}
