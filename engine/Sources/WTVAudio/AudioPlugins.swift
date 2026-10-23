import AudioToolbox
import AVFoundation
import Foundation
import WTVProtocol

/// Descrição de um Audio Unit de efeito instalado no sistema.
public struct AudioUnitInfo: Sendable {
    public let id: String          // "type:subtype:manufacturer" em FourCC
    public let name: String
    public let manufacturer: String
    public let desc: AudioComponentDescription

    public init(id: String, name: String, manufacturer: String, desc: AudioComponentDescription) {
        self.id = id; self.name = name; self.manufacturer = manufacturer; self.desc = desc
    }

    public static func fourcc(_ v: OSType) -> String {
        let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: b, encoding: .macOSRoman) ?? "????"
    }

    static func parse(_ s: String) -> OSType? {
        guard s.count == 4 else { return nil }
        var v: OSType = 0
        for c in s.unicodeScalars { v = v << 8 | OSType(c.value & 0xff) }
        return v
    }

    public static func parseId(_ id: String) -> AudioComponentDescription? {
        let parts = id.split(separator: ":").map(String.init)
        guard parts.count == 3, let t = parse(parts[0]), let st = parse(parts[1]), let m = parse(parts[2]) else { return nil }
        return AudioComponentDescription(componentType: t, componentSubType: st, componentManufacturer: m, componentFlags: 0, componentFlagsMask: 0)
    }
}

public enum AudioUnitCatalog {
    /// Efeitos (aufx) e efeitos musicais (aumf) instalados; só os que suportam float32 estéreo em processamento.
    public static func effects() -> [AudioUnitInfo] {
        var out: [AudioUnitInfo] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            var search = AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            var comp = AudioComponentFindNext(nil, &search)
            while let c = comp {
                var desc = AudioComponentDescription()
                AudioComponentGetDescription(c, &desc)
                var nameRef: Unmanaged<CFString>?
                AudioComponentCopyName(c, &nameRef)
                let full = nameRef?.takeRetainedValue() as String? ?? "?"
                let parts = full.components(separatedBy: ": ")
                let id = "\(AudioUnitInfo.fourcc(desc.componentType)):\(AudioUnitInfo.fourcc(desc.componentSubType)):\(AudioUnitInfo.fourcc(desc.componentManufacturer))"
                out.append(AudioUnitInfo(id: id, name: parts.count > 1 ? parts[1...].joined(separator: ": ") : full, manufacturer: parts.first ?? "", desc: desc))
                comp = AudioComponentFindNext(c, &search)
            }
        }
        return out.sorted { ($0.manufacturer, $0.name) < ($1.manufacturer, $1.name) }
    }
}

/// Um Audio Unit v2 instanciado para processar um canal (float32, 48 kHz, estéreo não intercalado, blocos ≤ 4096).
/// `process` é chamado no callback de tempo real: não aloca; o AU lê a entrada por callback de render.
public final class HostedAudioUnit: @unchecked Sendable {
    public let pluginId: String
    public let info: AudioUnitInfo
    public private(set) var unit: AudioUnit?
    public var bypass = false
    private var inputL: UnsafeMutablePointer<Float>
    private var inputR: UnsafeMutablePointer<Float>
    private var abl: UnsafeMutablePointer<AudioBufferList>
    private let maxFrames = 4096
    private var sampleTime: Float64 = 0
    private var failed = false

    public init?(pluginId: String, info: AudioUnitInfo) {
        self.pluginId = pluginId
        self.info = info
        inputL = .allocate(capacity: maxFrames); inputL.initialize(repeating: 0, count: maxFrames)
        inputR = .allocate(capacity: maxFrames); inputR.initialize(repeating: 0, count: maxFrames)
        abl = AudioBufferList.allocate(maximumBuffers: 2).unsafeMutablePointer
        var desc = info.desc
        guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }
        var u: AudioUnit?
        guard AudioComponentInstanceNew(comp, &u) == noErr, let u else { return nil }
        var fmt = AudioStreamBasicDescription(mSampleRate: AudioMixer.sampleRate, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                              mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, size)
        AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &fmt, size)
        var maxF = UInt32(maxFrames)
        AudioUnitSetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxF, UInt32(MemoryLayout<UInt32>.size))
        var cb = AURenderCallbackStruct(inputProc: { refCon, _, _, _, frames, ioData -> OSStatus in
            let me = Unmanaged<HostedAudioUnit>.fromOpaque(refCon).takeUnretainedValue()
            guard let ioData else { return noErr }
            let bufs = UnsafeMutableAudioBufferListPointer(ioData)
            let n = Int(min(frames, UInt32(me.maxFrames)))
            if bufs.count > 0 { bufs[0].mData?.copyMemory(from: me.inputL, byteCount: n * 4) }
            if bufs.count > 1 { bufs[1].mData?.copyMemory(from: me.inputR, byteCount: n * 4) }
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard AudioUnitInitialize(u) == noErr else { AudioComponentInstanceDispose(u); return nil }
        unit = u
    }

    deinit {
        if let unit { AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
        inputL.deallocate(); inputR.deallocate()
        free(abl)
    }

    /// Processa in-place `n` frames (L e R separados). Sem alocações.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames n: Int) {
        guard let unit, !bypass, !failed, n <= maxFrames else { return }
        inputL.update(from: left, count: n)
        inputR.update(from: right, count: n)
        let bufs = UnsafeMutableAudioBufferListPointer(abl)
        abl.pointee.mNumberBuffers = 2
        bufs[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: UnsafeMutableRawPointer(left))
        bufs[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: UnsafeMutableRawPointer(right))
        var flags = AudioUnitRenderActionFlags()
        var ts = AudioTimeStamp()
        ts.mSampleTime = sampleTime
        ts.mFlags = .sampleTimeValid
        let st = AudioUnitRender(unit, &flags, &ts, 0, UInt32(n), abl)
        if st != noErr { failed = true }
        sampleTime += Float64(n)
    }
}
