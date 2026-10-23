import CoreAudio
import Foundation
import WTVProtocol

/// Plano de mistura lido pelo callback de tempo real. Imutável; substituído por troca atómica.
public struct MixPlan: Sendable {
    public struct Channel: Sendable {
        public var gain: Float        // linear
        public var mute: Bool
        public var solo: Bool
        public var afv: Bool
        public var programWeight: Float // 0..1 (1 = está no Program; durante transições, parcial)
        public var pan: Float         // -1..1
        public var generator: Generator?
        public var buses: UInt8 = 1   // bit0 Master, bit1 A, bit2 B
        public var plugins: [String] = []   // ids de plugins (instâncias geridas pelo mixer), por ordem
    }

    public static let busMaster: UInt8 = 1, busA: UInt8 = 2, busB: UInt8 = 4
    public static func busMask(_ names: [String]) -> UInt8 {
        var m: UInt8 = 0
        for n in names { switch n { case "master": m |= busMaster; case "a": m |= busA; case "b": m |= busB; default: break } }
        return m
    }
    public static func busIndex(_ name: String) -> Int { name == "a" ? 1 : (name == "b" ? 2 : 0) }

    public enum Generator: Sendable {
        case tone(hz: Float, level: Float)
        case beep(hz: Float, level: Float, periodSeconds: Float, durationSeconds: Float)
        case ring   // PCM vindo de uma fonte real (ficheiro, câmara, ecrã) via AudioRing
    }

    public var channels: [InputId: Channel]
    public var order: [InputId]
    public var masterGain: Float
    public var masterMute: Bool
    public var anySolo: Bool
    public var monitorBus = 0        // 0 master, 1 A, 2 B
    public var streamBus = 0
    public var ndiBus = 0

    public init(channels: [InputId: Channel], order: [InputId], masterGain: Float, masterMute: Bool) {
        self.channels = channels
        self.order = order
        self.masterGain = masterGain
        self.masterMute = masterMute
        anySolo = channels.values.contains { $0.solo }
    }

    public static let empty = MixPlan(channels: [:], order: [], masterGain: 1, masterMute: false)

    public static func linear(db: Double) -> Float { db <= -60 ? 0 : Float(pow(10, db / 20)) }

    /// Constrói o plano a partir do estado (D7). `programWeight` segue a transição em curso para o AFV.
    public init(state: EngineState, transitionProgress: Double) {
        var chans: [InputId: Channel] = [:]
        for id in state.inputOrder {
            guard let input = state.inputs[id] else { continue }
            let a = state.audio.inputs[id] ?? AudioChannelState()
            var weight: Float = 0
            if state.program.inputId == id { weight = 1 - Float(state.program.transition == nil ? 0 : transitionProgress) }
            if state.program.transition != nil, state.preview.inputId == id { weight = Float(transitionProgress) }
            var gen: Generator?
            if input.hasAudio && input.kind != .synthetic { gen = .ring }
            if input.kind == .synthetic {
                let pattern = input.config["pattern"]?.stringValue ?? "colour"
                let tone = input.config["tone"]?.boolValue ?? false
                if pattern == "sync" { gen = .beep(hz: 1000, level: 0.5, periodSeconds: 1, durationSeconds: 0.04) }
                else if tone || pattern == "bars" { gen = .tone(hz: 1000, level: 0.25) }
            }
            var ch = Channel(gain: MixPlan.linear(db: a.db), mute: a.mute, solo: a.solo, afv: a.afv,
                             programWeight: state.program.ftb ? 0 : weight, pan: Float(a.pan), generator: gen)
            ch.buses = MixPlan.busMask(a.buses)
            ch.plugins = a.plugins.filter { !$0.bypass }.map(\.id)
            chans[id] = ch
        }
        self.init(channels: chans, order: state.inputOrder, masterGain: MixPlan.linear(db: state.audio.master.db), masterMute: state.audio.master.mute)
        monitorBus = MixPlan.busIndex(state.audio.monitor.bus)
        streamBus = MixPlan.busIndex(state.audio.outputBus["stream"] ?? "master")
        ndiBus = MixPlan.busIndex(state.audio.outputBus["ndi"] ?? "master")
    }
}

public struct MeterValue: Sendable {
    public var peakL: Float = 0, peakR: Float = 0, rmsL: Float = 0, rmsR: Float = 0
    public init() {}
}

public enum AudioOutputStatus: Sendable, Equatable {
    case none
    case device(name: String, sampleRate: Double, channels: Int)
    case nullClock(reason: String)
}

/// Mixer float32 48 kHz. O callback de tempo real gera as fontes sintéticas, aplica ganhos e escreve
/// o bus master num IOProc da HAL do dispositivo de monitorização. Sem alocações no callback.
/// Se o dispositivo não responder (watchdog de 2 s), um relógio nulo mantém o mixer e os VU a correr.
public final class AudioMixer: @unchecked Sendable {
    public static let sampleRate = 48000.0
    private var planLock = os_unfair_lock()
    private var plan: MixPlan = .empty
    private var phases: [InputId: Float] = [:]
    private var sampleClock: Int64 = 0
    private var meterLock = os_unfair_lock()
    private var masterMeter = MeterValue()
    private var inputMeters: [InputId: MeterValue] = [:]
    private var scratchL = [Float](repeating: 0, count: 8192)   // bus Master
    private var scratchR = [Float](repeating: 0, count: 8192)
    private var busAL = [Float](repeating: 0, count: 8192), busAR = [Float](repeating: 0, count: 8192)
    private var busBL = [Float](repeating: 0, count: 8192), busBR = [Float](repeating: 0, count: 8192)
    private var chanL = [Float](repeating: 0, count: 8192), chanR = [Float](repeating: 0, count: 8192)
    private var ringScratch = [Float](repeating: 0, count: 8192 * 2)
    private var tapScratch = [Float](repeating: 0, count: 8192 * 2)
    /// Bus escolhido para stream/gravação, intercalado, lido fora do callback. Ligar com `tapEnabled`.
    public let masterRing = AudioRing(capacityFrames: 48000)
    /// Bus escolhido para a saída NDI.
    public let ndiRing = AudioRing(capacityFrames: 48000)
    public var tapEnabled = false
    private var busMeters = [MeterValue(), MeterValue(), MeterValue()]
    /// Instâncias de plugins por id (criadas na camada de controlo com `ensurePlugin`).
    private var plugins: [String: HostedAudioUnit] = [:]

    private var rings: [InputId: AudioRing] = [:]
    private var device: AudioDeviceID = 0
    private var procID: AudioDeviceIOProcID?
    private var deviceChannels = 2
    private var nullTimer: DispatchSourceTimer?
    private var statusLock = os_unfair_lock()
    private var _status: AudioOutputStatus = .none

    public init() {}

    public var status: AudioOutputStatus {
        os_unfair_lock_lock(&statusLock); defer { os_unfair_lock_unlock(&statusLock) }
        return _status
    }

    private func setStatus(_ s: AudioOutputStatus) {
        os_unfair_lock_lock(&statusLock); _status = s; os_unfair_lock_unlock(&statusLock)
    }

    // MARK: - Dispositivo de saída

    /// Abre o dispositivo (UID, ou o de saída por omissão se nil) numa thread própria com watchdog.
    /// Devolve o estado resultante. Se bloquear, a thread fica presa no coreaudiod e o mixer segue em relógio nulo.
    /// Fica true quando uma chamada à HAL não respondeu. A partir daí este processo não volta a
    /// chamar a HAL (as chamadas seguintes bloqueariam também); só um reinício do motor limpa isto.
    public private(set) static var halUnresponsive = false

    /// Corre `body` numa thread própria; se exceder `timeout` devolve `fallback` e marca a HAL como indisponível.
    public static func withWatchdog<T>(_ label: String, timeout: TimeInterval, fallback: T, _ body: @escaping () -> T) -> T {
        if halUnresponsive { return fallback }
        let done = DispatchSemaphore(value: 0)
        let box = GenericBox<T>()
        let t = Thread { box.value = body(); done.signal() }
        t.name = "wtv.audio.\(label)"
        t.start()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            halUnresponsive = true
            return fallback
        }
        return box.value ?? fallback
    }

    @discardableResult
    public func openOutput(deviceUID: String?, timeout: TimeInterval = 2.0) -> AudioOutputStatus {
        closeOutput()
        if AudioMixer.halUnresponsive {
            let s = AudioOutputStatus.nullClock(reason: "o serviço de áudio do macOS (coreaudiod) não responde; reinicie o motor ou o Mac")
            startNullClock(); setStatus(s); return s
        }
        let box = ResultBox()
        box.result = AudioMixer.withWatchdog("open", timeout: timeout, fallback: .nullClock(reason: "o dispositivo de áudio não respondeu em \(Int(timeout)) s (coreaudiod)")) { [self] in
            self.openOutputBlocking(deviceUID: deviceUID)
        }
        if case .nullClock = box.result, AudioMixer.halUnresponsive {
            startNullClock(); setStatus(box.result); return box.result
        }
        switch box.result {
        case .device:
            setStatus(box.result)
        default:
            startNullClock()
            setStatus(box.result)
        }
        return box.result
    }

    private final class ResultBox: @unchecked Sendable { var result: AudioOutputStatus = .none }
    private final class GenericBox<T>: @unchecked Sendable { var value: T?; init() {} }

    private func openOutputBlocking(deviceUID: String?) -> AudioOutputStatus {
        guard let dev = AudioMixer.resolveDevice(uid: deviceUID) else { return .nullClock(reason: "dispositivo não encontrado") }
        var rateAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var rate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(dev, &rateAddr, 0, nil, &size, &rate)
        if rate != AudioMixer.sampleRate {
            var want = AudioMixer.sampleRate
            if AudioObjectSetPropertyData(dev, &rateAddr, 0, nil, UInt32(MemoryLayout<Double>.size), &want) != noErr {
                return .nullClock(reason: "dispositivo não suporta 48 kHz (\(Int(rate)) Hz)")
            }
            rate = want
        }
        var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var fmt = AudioStreamBasicDescription()
        var fsize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(dev, &fmtAddr, 0, nil, &fsize, &fmt) == noErr else { return .nullClock(reason: "sem formato de saída") }
        let isFloat = fmt.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let interleaved = fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        guard isFloat, fmt.mBitsPerChannel == 32 else { return .nullClock(reason: "formato não é float32") }
        let channels = Int(fmt.mChannelsPerFrame)
        var pid: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&pid, dev, nil) { [unowned self] _, _, _, outData, _ in
            self.ioProc(outData, channels: channels, interleaved: interleaved)
        }
        guard st == noErr, let pid else { return .nullClock(reason: "CreateIOProcID \(st)") }
        guard AudioDeviceStart(dev, pid) == noErr else {
            AudioDeviceDestroyIOProcID(dev, pid)
            return .nullClock(reason: "AudioDeviceStart falhou")
        }
        device = dev
        procID = pid
        deviceChannels = channels
        return .device(name: AudioMixer.deviceName(dev), sampleRate: rate, channels: channels)
    }

    public func closeOutput() {
        nullTimer?.cancel(); nullTimer = nil
        if let procID, device != 0, !AudioMixer.halUnresponsive {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
        }
        procID = nil
        device = 0
        setStatus(.none)
    }

    private func startNullClock() {
        nullTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "wtv.audio.null", qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.renderStereo(frames: 480) }
        t.resume()
        nullTimer = t
    }

    private func ioProc(_ outData: UnsafeMutablePointer<AudioBufferList>, channels: Int, interleaved: Bool) {
        let buffers = UnsafeMutableAudioBufferListPointer(outData)
        guard buffers.count > 0 else { return }
        if interleaved {
            guard let out = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let frames = Int(buffers[0].mDataByteSize) / (4 * max(channels, 1))
            let n = renderStereo(frames: frames)
            for i in 0..<n {
                out[i * channels] = scratchL[i]
                if channels > 1 { out[i * channels + 1] = scratchR[i] }
                if channels > 2 { for c in 2..<channels { out[i * channels + c] = 0 } }
            }
        } else {
            let frames = Int(buffers[0].mDataByteSize) / 4
            let n = renderStereo(frames: frames)
            for (c, buf) in buffers.enumerated() {
                guard let out = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let src = c == 0 ? scratchL : (c == 1 ? scratchR : nil)
                for i in 0..<n { out[i] = src?[i] ?? 0 }
            }
        }
    }

    // MARK: - Plano e VU

    public func setPlan(_ p: MixPlan) {
        os_unfair_lock_lock(&planLock)
        plan = p
        for id in p.order where phases[id] == nil { phases[id] = 0 } // alocação fora do callback
        os_unfair_lock_unlock(&planLock)
    }

    /// Cria (ou devolve) o anel PCM de uma fonte real. Chamado na camada de controlo.
    public func ring(for id: InputId) -> AudioRing {
        os_unfair_lock_lock(&planLock); defer { os_unfair_lock_unlock(&planLock) }
        if let r = rings[id] { return r }
        let r = AudioRing(capacityFrames: 48000 * 2)
        rings[id] = r
        return r
    }

    public func removeRing(for id: InputId) {
        os_unfair_lock_lock(&planLock); rings[id] = nil; os_unfair_lock_unlock(&planLock)
    }

    public func meters() -> (master: MeterValue, inputs: [InputId: MeterValue]) {
        os_unfair_lock_lock(&meterLock); defer { os_unfair_lock_unlock(&meterLock) }
        return (masterMeter, inputMeters)
    }

    public func busMeterValues() -> [MeterValue] {
        os_unfair_lock_lock(&meterLock); defer { os_unfair_lock_unlock(&meterLock) }
        return busMeters
    }

    // MARK: - Plugins (camada de controlo)

    /// Cria a instância do plugin se ainda não existir. Devolve false se o AU não puder ser instanciado.
    @discardableResult
    public func ensurePlugin(id: String, component: AudioUnitInfo) -> Bool {
        os_unfair_lock_lock(&planLock); let exists = plugins[id] != nil; os_unfair_lock_unlock(&planLock)
        if exists { return true }
        guard let unit = HostedAudioUnit(pluginId: id, info: component) else { return false }
        os_unfair_lock_lock(&planLock); plugins[id] = unit; os_unfair_lock_unlock(&planLock)
        return true
    }

    public func removePlugin(id: String) {
        os_unfair_lock_lock(&planLock); let u = plugins.removeValue(forKey: id); os_unfair_lock_unlock(&planLock)
        _ = u // libertado fora do callback
    }

    public func plugin(id: String) -> HostedAudioUnit? {
        os_unfair_lock_lock(&planLock); defer { os_unfair_lock_unlock(&planLock) }
        return plugins[id]
    }

    public var pluginIds: [String] {
        os_unfair_lock_lock(&planLock); defer { os_unfair_lock_unlock(&planLock) }
        return Array(plugins.keys)
    }

    // MARK: - Tempo real

    /// Mistura `frames` amostras: cada canal → plugins → ganho/pan → barramentos Master/A/B.
    /// scratchL/R recebem o barramento de monitorização (o que vai para o dispositivo). Devolve frames renderizados.
    @discardableResult
    private func renderStereo(frames: Int) -> Int {
        let n = min(frames, scratchL.count)
        for i in 0..<n { scratchL[i] = 0; scratchR[i] = 0; busAL[i] = 0; busAR[i] = 0; busBL[i] = 0; busBR[i] = 0 }

        guard os_unfair_lock_trylock(&planLock) else { sampleClock += Int64(n); return n }
        let plan = self.plan
        let sr = Float(AudioMixer.sampleRate)

        for id in plan.order {
            guard let ch = plan.channels[id], let gen = ch.generator else { continue }
            var inPeak: Float = 0, inSum: Float = 0
            // 1) fonte → chanL/chanR
            switch gen {
            case .ring:
                var got = 0
                if let ring = rings[id] { got = ring.read(into: &ringScratch, frames: n) }
                for i in 0..<n {
                    chanL[i] = i < got ? ringScratch[i * 2] : 0
                    chanR[i] = i < got ? ringScratch[i * 2 + 1] : 0
                }
            case .tone(let hz, let level):
                var phase = phases[id] ?? 0
                for i in 0..<n { let v = sin(phase) * level; chanL[i] = v; chanR[i] = v; phase += 2 * .pi * hz / sr; if phase > 2 * .pi { phase -= 2 * .pi } }
                phases[id] = phase
            case .beep(let hz, let level, let period, let duration):
                var phase = phases[id] ?? 0
                for i in 0..<n {
                    let t = Float(Double(sampleClock + Int64(i)) / AudioMixer.sampleRate)
                    let inPeriod = t - floor(t / period) * period
                    let v = inPeriod < duration ? sin(phase) * level : 0
                    chanL[i] = v; chanR[i] = v
                    phase += 2 * .pi * hz / sr; if phase > 2 * .pi { phase -= 2 * .pi }
                }
                phases[id] = phase
            }
            // 2) plugins (in-place)
            if !ch.plugins.isEmpty {
                chanL.withUnsafeMutableBufferPointer { l in
                    chanR.withUnsafeMutableBufferPointer { r in
                        for pid in ch.plugins { plugins[pid]?.process(left: l.baseAddress!, right: r.baseAddress!, frames: n) }
                    }
                }
            }
            // 3) VU pré-fader, ganho, AFV, pan, barramentos
            var g = ch.mute ? 0 : ch.gain
            if plan.anySolo && !ch.solo { g = 0 }
            if ch.afv { g *= ch.programWeight }
            let panL: Float = ch.pan <= 0 ? 1 : 1 - ch.pan
            let panR: Float = ch.pan >= 0 ? 1 : 1 + ch.pan
            let toM = ch.buses & MixPlan.busMaster != 0, toA = ch.buses & MixPlan.busA != 0, toB = ch.buses & MixPlan.busB != 0
            for i in 0..<n {
                let l0 = chanL[i], r0 = chanR[i]
                inPeak = max(inPeak, max(abs(l0), abs(r0)))
                inSum += (l0 * l0 + r0 * r0) * 0.5
                let l = l0 * g * panL, r = r0 * g * panR
                if toM { scratchL[i] += l; scratchR[i] += r }
                if toA { busAL[i] += l; busAR[i] += r }
                if toB { busBL[i] += l; busBR[i] += r }
            }
            var m = MeterValue()
            m.peakL = inPeak; m.peakR = inPeak
            m.rmsL = sqrt(inSum / Float(max(n, 1))); m.rmsR = m.rmsL
            inputMeters[id] = m
        }
        os_unfair_lock_unlock(&planLock)

        // 4) ganho master (só no bus Master) + limitador simples; VU por barramento
        let mg = plan.masterMute ? 0 : plan.masterGain
        var peaks = [Float](repeating: 0, count: 6), sums = [Float](repeating: 0, count: 6)
        for i in 0..<n {
            let ml = max(-1, min(1, scratchL[i] * mg)), mr = max(-1, min(1, scratchR[i] * mg))
            scratchL[i] = ml; scratchR[i] = mr
            busAL[i] = max(-1, min(1, busAL[i])); busAR[i] = max(-1, min(1, busAR[i]))
            busBL[i] = max(-1, min(1, busBL[i])); busBR[i] = max(-1, min(1, busBR[i]))
            peaks[0] = max(peaks[0], abs(ml)); peaks[1] = max(peaks[1], abs(mr)); sums[0] += ml * ml; sums[1] += mr * mr
            peaks[2] = max(peaks[2], abs(busAL[i])); peaks[3] = max(peaks[3], abs(busAR[i])); sums[2] += busAL[i] * busAL[i]; sums[3] += busAR[i] * busAR[i]
            peaks[4] = max(peaks[4], abs(busBL[i])); peaks[5] = max(peaks[5], abs(busBR[i])); sums[4] += busBL[i] * busBL[i]; sums[5] += busBR[i] * busBR[i]
        }
        sampleClock += Int64(n)

        // 5) taps: stream/gravação e NDI lêem o barramento escolhido
        if tapEnabled {
            writeTap(masterRing, bus: plan.streamBus, n: n)
            writeTap(ndiRing, bus: plan.ndiBus, n: n)
        }
        // 6) o dispositivo de monitorização ouve o barramento escolhido (copiado para scratch, que o IOProc lê)
        if plan.monitorBus == 1 { for i in 0..<n { scratchL[i] = busAL[i]; scratchR[i] = busAR[i] } }
        else if plan.monitorBus == 2 { for i in 0..<n { scratchL[i] = busBL[i]; scratchR[i] = busBR[i] } }

        if os_unfair_lock_trylock(&meterLock) {
            for b in 0..<3 {
                busMeters[b].peakL = max(peaks[b * 2], busMeters[b].peakL * 0.8)
                busMeters[b].peakR = max(peaks[b * 2 + 1], busMeters[b].peakR * 0.8)
                busMeters[b].rmsL = sqrt(sums[b * 2] / Float(max(n, 1)))
                busMeters[b].rmsR = sqrt(sums[b * 2 + 1] / Float(max(n, 1)))
            }
            masterMeter = busMeters[0]
            os_unfair_lock_unlock(&meterLock)
        }
        return n
    }

    private func writeTap(_ ring: AudioRing, bus: Int, n: Int) {
        switch bus {
        case 1: for i in 0..<n { tapScratch[i * 2] = busAL[i]; tapScratch[i * 2 + 1] = busAR[i] }
        case 2: for i in 0..<n { tapScratch[i * 2] = busBL[i]; tapScratch[i * 2 + 1] = busBR[i] }
        default: for i in 0..<n { tapScratch[i * 2] = scratchL[i]; tapScratch[i * 2 + 1] = scratchR[i] }
        }
        tapScratch.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: n) }
    }

    // MARK: - VU em binário (docs/PROTOCOLO.md §5, streamId 16)

    public static func float16(_ v: Float) -> UInt16 {
        Float16(max(0, min(4, v))).bitPattern
    }

    public func metersFrame(order: [InputId]) -> Data {
        let (master, inputs) = meters()
        var body = Data()
        var c = UInt16(min(order.count, 250) + 3).littleEndian
        body.append(Data(bytes: &c, count: 2))
        func append(_ index: UInt8, _ m: MeterValue) {
            body.append(index)
            for v in [m.peakL, m.peakR, m.rmsL, m.rmsR] {
                var h = AudioMixer.float16(v).littleEndian
                body.append(Data(bytes: &h, count: 2))
            }
        }
        let buses = busMeterValues()
        for (i, id) in order.prefix(250).enumerated() { append(UInt8(i), inputs[id] ?? MeterValue()) }
        append(253, buses[2])
        append(254, buses[1])
        append(255, master)
        return body
    }

    // MARK: - HAL helpers (consultas de propriedades; não bloqueiam nesta máquina)

    public static func resolveDevice(uid: String?) -> AudioDeviceID? {
        if let uid {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var cf = uid as CFString
            var dev = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let st = withUnsafePointer(to: &cf) { ptr in
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), ptr, &size, &dev)
            }
            return st == noErr && dev != 0 ? dev : nil
        }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return st == noErr && dev != 0 ? dev : nil
    }

    public static func deviceName(_ dev: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name) == noErr ? name as String : "?"
    }

    public static func deviceUID(_ dev: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr ? uid as String : ""
    }

    /// `listDevices` com watchdog (consultas à HAL também bloqueiam quando o coreaudiod está preso).
    public static func listDevicesSafely(timeout: TimeInterval = 2.0) -> (output: [AudioDevice], input: [AudioDevice]) {
        withWatchdog("list", timeout: timeout, fallback: ([], [])) { listDevices() }
    }

    /// Lista dispositivos de saída/entrada (nome, uid, canais, taxa) sem abrir nenhum.
    public static func listDevices() -> (output: [AudioDevice], input: [AudioDevice]) {
        var listAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size) == noErr else { return ([], []) }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size, &ids)
        let defaultOut = resolveDevice(uid: nil)
        var outs: [AudioDevice] = [], ins: [AudioDevice] = []
        for id in ids {
            let name = deviceName(id), uid = deviceUID(id)
            var rateAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var rate = 0.0; var rs = UInt32(MemoryLayout<Double>.size)
            AudioObjectGetPropertyData(id, &rateAddr, 0, nil, &rs, &rate)
            for (scope, isOut) in [(kAudioObjectPropertyScopeOutput, true), (kAudioObjectPropertyScopeInput, false)] {
                var cfgAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
                var csize: UInt32 = 0
                guard AudioObjectGetPropertyDataSize(id, &cfgAddr, 0, nil, &csize) == noErr, csize > 0 else { continue }
                let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(csize), alignment: MemoryLayout<AudioBufferList>.alignment)
                defer { raw.deallocate() }
                let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
                guard AudioObjectGetPropertyData(id, &cfgAddr, 0, nil, &csize, abl) == noErr else { continue }
                let channels = UnsafeMutableAudioBufferListPointer(abl).reduce(0) { $0 + Int($1.mNumberChannels) }
                guard channels > 0 else { continue }
                let d = AudioDevice(uid: uid, name: name, channels: channels, sampleRate: rate, isDefault: isOut && id == defaultOut)
                if isOut { outs.append(d) } else { ins.append(d) }
            }
        }
        return (outs, ins)
    }
}

/// Anel SPSC de PCM float32 estéreo intercalado. Produtor: thread da fonte; consumidor: callback de áudio.
public final class AudioRing: @unchecked Sendable {
    private var buffer: [Float]
    private let capacity: Int // em frames
    private var head = 0      // escrita (frames)
    private var tail = 0      // leitura (frames)
    private var lock = os_unfair_lock()

    public init(capacityFrames: Int) {
        capacity = capacityFrames
        buffer = [Float](repeating: 0, count: capacityFrames * 2)
    }

    public var availableFrames: Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return head - tail
    }

    public var freeFrames: Int { capacity - availableFrames }

    /// Escreve `frames` frames intercalados; descarta o que não couber. Devolve frames escritos.
    @discardableResult
    public func write(_ samples: UnsafePointer<Float>, frames: Int) -> Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let n = min(frames, capacity - (head - tail))
        for i in 0..<n {
            let idx = ((head + i) % capacity) * 2
            buffer[idx] = samples[i * 2]
            buffer[idx + 1] = samples[i * 2 + 1]
        }
        head += n
        return n
    }

    /// Lê até `frames` frames para `out` (intercalado). Devolve frames lidos.
    public func read(into out: inout [Float], frames: Int) -> Int {
        guard os_unfair_lock_trylock(&lock) else { return 0 }
        defer { os_unfair_lock_unlock(&lock) }
        let n = min(frames, head - tail, out.count / 2)
        for i in 0..<n {
            let idx = ((tail + i) % capacity) * 2
            out[i * 2] = buffer[idx]
            out[i * 2 + 1] = buffer[idx + 1]
        }
        tail += n
        if tail >= capacity { tail -= capacity; head -= capacity }
        return n
    }

    public func clear() {
        os_unfair_lock_lock(&lock); head = 0; tail = 0; os_unfair_lock_unlock(&lock)
    }
}
