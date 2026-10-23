import Foundation
import Logging
import WTVAudio
import WTVCore
import WTVInputs
import WTVOutputs
import WTVProtocol
import WTVVideo

/// Cria e destrói fontes reais a partir do estado (declarativo) e encaminha comandos media.*/title.*.
actor InputManager {
    private let store: StateStore
    private let frames: FrameStore
    private let mixer: AudioMixer?
    private var sources: [InputId: any InputSource] = [:]
    private var kinds: [InputId: InputKind] = [:]
    private let log = Logger(label: "wtv.inputs")
    private var task: Task<Void, Never>?

    init(store: StateStore, frames: FrameStore, mixer: AudioMixer?) {
        self.store = store
        self.frames = frames
        self.mixer = mixer
    }

    func start() async {
        await refreshDevices()
        let st = await store.state
        for (_, ch) in st.audio.inputs {
            for pl in ch.plugins { try? command("audio.ensurePlugin", inputId: "", params: .object(["pluginId": .string(pl.id), "componentId": .string(pl.componentId)])) }
        }
        await reconcile(st)
        let (_, patches) = await store.subscribe()
        task = Task { [weak self] in
            for await _ in patches {
                guard let self else { return }
                await self.reconcile(await self.store.state)
            }
        }
    }

    func refreshDevices() async {
        let cams = DeviceDiscovery.cameras()
        let displays = ScreenInput.displays()
        // A descoberta NDI espera até 1,5 s: fora do actor para não bloquear comandos.
        let ndi = await Task.detached { NDIDiscovery.shared.sources() }.value
        let units = AudioUnitCatalog.effects().map { AudioUnitDevice(id: $0.id, name: $0.name, manufacturer: $0.manufacturer) }
        await store.mutate { s in
            s.devices.video = cams
            s.devices.displays = displays
            s.devices.ndiSources = ndi
            s.devices.audioUnits = units
            s.permissions["camera"] = InputManager.cameraPermission()
        }
    }

    private static func cameraPermission() -> String {
        switch AVCaptureDeviceAuth.status() {
        case "authorized": return "granted"
        case "denied", "restricted": return "denied"
        default: return "notDetermined"
        }
    }

    private func reconcile(_ state: EngineState) {
        // remover
        for id in sources.keys where state.inputs[id] == nil {
            sources[id]?.stop()
            sources[id] = nil
            kinds[id] = nil
            frames.remove(id)
        }
        // criar
        for (id, input) in state.inputs where sources[id] == nil && input.kind != .synthetic {
            do {
                if let src = try make(input, fps: state.project.raster.fps) {
                    sources[id] = src
                    kinds[id] = input.kind
                    src.start()
                }
            } catch {
                log.warning("fonte \(id) (\(input.kind.rawValue)): \(error)")
                let detail = "\(error)"
                Task { await store.mutate { $0.inputs[id]?.status = .error; $0.inputs[id]?.statusCode = detail } }
            }
        }
    }

    private func make(_ input: InputState, fps: Double) throws -> (any InputSource)? {
        let ctx = InputContext(id: input.id, frames: frames, mixer: mixer, report: { [store] id, status, format, code in
            Task {
                await store.mutate { s in
                    guard s.inputs[id] != nil else { return }
                    s.inputs[id]?.status = status
                    if let format { s.inputs[id]?.format = format }
                    s.inputs[id]?.statusCode = code
                }
            }
        }, reportMedia: { [store] id, transport in
            Task { await store.mutate { $0.inputs[id]?.media = transport } }
        })
        switch input.kind {
        case .media: return try MediaInput(id: input.id, ctx: ctx, config: input.config)
        case .image: return ImageInput(id: input.id, ctx: ctx, config: input.config)
        case .title: return TitleInput(id: input.id, ctx: ctx, config: input.config)
        case .camera: return try CameraInput(id: input.id, ctx: ctx, config: input.config)
        case .screen: return ScreenInput(id: input.id, ctx: ctx, config: input.config, fps: fps)
        case .ndi: return try NDIInput(id: input.id, ctx: ctx, config: input.config)
        case .srt: return try SRTInput(id: input.id, ctx: ctx, config: input.config)
        case .decklink:
            throw InputError.unsupported("DeckLink ainda não disponível")
        case .synthetic: return nil
        }
    }

    /// media.*, title.setFields, input.update(config), audio.* (plugins)
    func command(_ name: String, inputId: InputId, params: JSONValue) throws {
        if name.hasPrefix("audio.") {
            guard let mixer else { throw RpcErrorBody.domain("CAPABILITY_MISSING", "sem mixer de áudio") }
            switch name {
            case "audio.ensurePlugin":
                guard let pid = params["pluginId"]?.stringValue, let cid = params["componentId"]?.stringValue,
                      let desc = AudioUnitInfo.parseId(cid) else { throw RpcErrorBody.invalidParams("componentId") }
                let info = AudioUnitCatalog.effects().first { $0.id == cid } ?? AudioUnitInfo(id: cid, name: cid, manufacturer: "", desc: desc)
                guard mixer.ensurePlugin(id: pid, component: info) else { throw RpcErrorBody.domain("DEVICE_UNAVAILABLE", "o Audio Unit não inicializou") }
            case "audio.removePlugin":
                if let pid = params["pluginId"]?.stringValue { AudioPluginWindow.close(pluginId: pid); mixer.removePlugin(id: pid) }
            case "audio.openPluginUI":
                guard let pid = params["pluginId"]?.stringValue, let plugin = mixer.plugin(id: pid) else { throw RpcErrorBody.domain("INPUT_NOT_FOUND", "plugin") }
                AudioPluginWindow.open(plugin: plugin, title: plugin.info.name)
            default: break
            }
            return
        }
        guard let src = sources[inputId] else { throw RpcErrorBody.domain("INPUT_NOT_FOUND", inputId) }
        if name == "input.update", let cfg = params["config"] { src.update(config: cfg); return }
        try src.handle(command: name, params: params)
    }

    func imageUpload(inputId: InputId, data: Data) throws {
        guard let img = sources[inputId] as? ImageInput else { throw RpcErrorBody.domain("INPUT_NOT_FOUND", inputId) }
        img.setImageData(data)
    }
}

import AVFoundation
enum AVCaptureDeviceAuth {
    static func status() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "notDetermined"
        }
    }
}
