import Foundation
import Logging
import WTVProtocol

/// Despacha métodos JSON-RPC para o estado. Os métodos que precisam de hardware
/// (câmaras, codificadores) chamam o `EngineHooks`; nesta fase só o estado é alterado.
public actor CommandRouter {
    public let store: StateStore
    public nonisolated let capabilities: Capabilities
    public nonisolated let engineVersion: String
    private let log = Logger(label: "wtv.commands")
    private var recentTxns: [String: (at: Date, result: Result<JSONValue, RpcErrorBody>?)] = [:]
    /// Pasta onde os projectos podem ser gravados/lidos (project.save/load nunca saem daqui).
    public var projectsDir: URL?

    /// Pontos de extensão para os módulos de tempo real (preenchidos nas fases seguintes).
    public struct Hooks: Sendable {
        public var shutdown: @Sendable (Bool) async -> Void
        /// true quando há compositor a animar transições por tick; false conclui-as de imediato.
        public var animatesTransitions: Bool
        /// Comandos dirigidos a uma fonte real (media.*, title.setFields, input.update).
        public var inputCommand: @Sendable (String, InputId, JSONValue) async throws -> Void
        /// Re-enumera câmaras, ecrãs e dispositivos de áudio.
        public var refreshDevices: @Sendable () async -> Void
        /// output.*, record.* (o OutputManager actualiza o estado das saídas).
        public var outputCommand: @Sendable (String, JSONValue) async throws -> Void
        public init(shutdown: @escaping @Sendable (Bool) async -> Void, animatesTransitions: Bool = false,
                    inputCommand: @escaping @Sendable (String, InputId, JSONValue) async throws -> Void = { _, _, _ in },
                    refreshDevices: @escaping @Sendable () async -> Void = {},
                    outputCommand: @escaping @Sendable (String, JSONValue) async throws -> Void = { _, _ in }) {
            self.shutdown = shutdown
            self.animatesTransitions = animatesTransitions
            self.inputCommand = inputCommand
            self.refreshDevices = refreshDevices
            self.outputCommand = outputCommand
        }
    }
    private let hooks: Hooks

    public init(store: StateStore, capabilities: Capabilities, engineVersion: String, hooks: Hooks) {
        self.store = store
        self.capabilities = capabilities
        self.engineVersion = engineVersion
        self.hooks = hooks
    }

    public func setProjectsDir(_ url: URL) { projectsDir = url }

    public func handle(_ request: RpcRequest) async -> RpcResponse {
        let params = request.params ?? .object([:])
        let txn = params["txnId"]?.stringValue
        // Repetição de um comando já concluído (reconexão): devolve o mesmo resultado, não executa de novo.
        if let txn, let cached = recentTxns[txn]?.result {
            switch cached {
            case .success(let v): return RpcResponse(id: request.id, result: v)
            case .failure(let e): return RpcResponse(id: request.id, error: e)
            }
        }
        if let txn, recentTxns[txn] != nil {
            return RpcResponse(id: request.id, error: .domain("ALREADY_RUNNING", "comando ainda em execução"))
        }
        if let txn {
            let now = Date()
            recentTxns = recentTxns.filter { now.timeIntervalSince($0.value.at) < 60 }
            recentTxns[txn] = (now, nil)
        }
        do {
            let result = try await dispatch(request.method, params)
            if let txn { recentTxns[txn]?.result = .success(result) }
            return RpcResponse(id: request.id, result: result)
        } catch let e as RpcErrorBody {
            if let txn { recentTxns[txn] = nil } // deixa o cliente tentar outra vez
            return RpcResponse(id: request.id, error: e)
        } catch {
            if let txn { recentTxns[txn] = nil }
            return RpcResponse(id: request.id, error: .domain("INTERNAL", "\(error)"))
        }
    }

    private func dedupe(_ params: JSONValue) throws {} // tratado em handle(_:)

    /// Resolve um nome de projecto para dentro de projectsDir; recusa caminhos absolutos e "..".
    private func projectURL(_ raw: String) throws -> URL {
        guard let dir = projectsDir else { throw RpcErrorBody.domain("CAPABILITY_MISSING", "sem pasta de projectos") }
        var name = (raw as NSString).lastPathComponent
        guard !name.isEmpty, !name.hasPrefix("."), !raw.contains("..") else { throw RpcErrorBody.invalidParams("nome de projecto inválido") }
        if !name.hasSuffix(".wtv.json") { name = name.replacingOccurrences(of: ".json", with: "") + ".wtv.json" }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private func requireInput(_ params: JSONValue, key: String = "inputId") async throws -> InputId {
        guard let id = params[key]?.stringValue else { throw RpcErrorBody.invalidParams("\(key) em falta") }
        guard await store.state.inputs[id] != nil else { throw RpcErrorBody.domain("INPUT_NOT_FOUND", id) }
        return id
    }

    private func dispatch(_ method: String, _ p: JSONValue) async throws -> JSONValue {
        switch method {
        case "session.hello":
            let snap = await store.snapshot()
            let hello = HelloResult(protocolVersion: protocolVersion, engineVersion: engineVersion,
                                    capabilities: capabilities, snapshot: snap)
            return try JSONCoding.tree(hello)

        case "state.resync":
            let last = p["lastRev"]?.intValue ?? -1
            if let patches = await store.patches(since: last) {
                return try JSONCoding.tree(["patches": patches])
            }
            return try JSONCoding.tree(["snapshot": await store.snapshot()])

        case "input.add":
            guard let kindRaw = p["kind"]?.stringValue, let kind = InputKind(rawValue: kindRaw) else {
                throw RpcErrorBody.invalidParams("kind")
            }
            let id = "in_" + String(UUID().uuidString.prefix(6)).lowercased()
            let name = p["name"]?.stringValue ?? defaultName(for: kind, p["config"] ?? .object([:]))
            let config = p["config"] ?? .object([:])
            try await store.mutate { s in
                var input = InputState(id: id, kind: kind, name: name, config: config, hasAudio: kind == .media || kind == .camera)
                input.status = kind == .synthetic ? .live : .starting
                s.inputs[id] = input
                s.inputOrder.append(id)
                s.audio.inputs[id] = AudioChannelState()
                if s.program.inputId == nil { s.program.inputId = id }
                else if s.preview.inputId == nil { s.preview.inputId = id }
                s.refreshMultiview()
            }
            return .object(["inputId": .string(id)])

        case "input.update":
            let id = try await requireInput(p)
            try await store.mutate { s in
                guard var input = s.inputs[id] else { return }
                if let name = p["name"]?.stringValue { input.name = name }
                if let fit = p["fit"]?.stringValue { input.fit = fit }
                if let d = p["videoDelayFrames"]?.intValue { input.videoDelayFrames = d }
                if let lb = p["lowBandwidth"]?.boolValue { input.lowBandwidth = lb }
                if let cfg = p["config"], case .object(let patch) = cfg, case .object(var current) = input.config {
                    for (k, v) in patch { current[k] = v }
                    input.config = .object(current)
                }
                s.inputs[id] = input
            }
            if p["config"] != nil { try await hooks.inputCommand("input.update", id, p) }
            return .object([:])

        case "media.play", "media.pause", "media.stop", "media.seek", "media.setLoop", "title.setFields":
            let id = try await requireInput(p)
            if method == "media.play" || method == "media.stop" { try dedupe(p) }
            if method == "title.setFields", let f = p["fields"], case .object(let fields) = f {
                await store.mutate { s in
                    guard var cfg = s.inputs[id]?.config.objectValue else { return }
                    var cur = cfg["fields"]?.objectValue ?? [:]
                    for (k, v) in fields { cur[k] = v }
                    cfg["fields"] = .object(cur)
                    s.inputs[id]?.config = .object(cfg)
                }
            }
            try await hooks.inputCommand(method, id, p)
            return .object([:])

        case "input.remove":
            let id = try await requireInput(p)
            try await store.mutate { s in
                s.inputs[id] = nil
                s.inputOrder.removeAll { $0 == id }
                s.audio.inputs[id] = nil
                if s.program.inputId == id { s.program.inputId = s.inputOrder.first }
                if s.preview.inputId == id { s.preview.inputId = nil }
                for i in s.overlays.indices where s.overlays[i].inputId == id {
                    s.overlays[i].inputId = nil
                    s.overlays[i].on = false
                }
                s.refreshMultiview()
            }
            return .object([:])

        case "input.reorder":
            guard let order = p["order"]?.arrayValue?.compactMap(\.stringValue) else { throw RpcErrorBody.invalidParams("order") }
            try await store.mutate { s in
                let known = Set(s.inputOrder)
                guard Set(order) == known else { throw RpcErrorBody.invalidParams("order não corresponde às fontes") }
                s.inputOrder = order
                s.refreshMultiview()
            }
            return .object([:])

        case "switcher.setPreview":
            let id = try await requireInput(p)
            await store.mutate { $0.preview.inputId = id }
            return .object([:])

        case "switcher.cut":
            try dedupe(p)
            await store.mutate { s in
                let pvw = s.preview.inputId
                s.preview.inputId = s.program.inputId
                s.program.inputId = pvw
                s.program.transition = nil
            }
            return .object([:])

        case "switcher.transition":
            try dedupe(p)
            let kind = p["kind"]?.stringValue ?? "fade"
            let frames = p["durationFrames"]?.intValue ?? 25
            guard ["fade", "wipe", "dip", "stinger"].contains(kind) else { throw RpcErrorBody.invalidParams("kind") }
            var wipe: WipeSpec?
            if let w = p["wipe"] {
                wipe = WipeSpec(direction: w["direction"]?.stringValue ?? "left", softness: w["softness"]?.doubleValue ?? 0.05)
            }
            await store.mutate { s in
                guard s.preview.inputId != nil else { return }
                s.program.transition = TransitionState(kind: kind, durationFrames: max(1, frames), progress: 0, auto: true, wipe: wipe, colour: p["colour"]?.stringValue)
            }
            // Sem compositor: a transição conclui de imediato.
            if hooks.animatesTransitions { return .object([:]) }
            await store.mutate { s in
                guard s.program.transition != nil else { return }
                let pvw = s.preview.inputId
                s.preview.inputId = s.program.inputId
                s.program.inputId = pvw
                s.program.transition = nil
            }
            return .object([:])

        case "switcher.tbar":
            let pos = min(1, max(0, p["position"]?.doubleValue ?? 0))
            await store.mutate { s in
                if pos >= 1 {
                    let pvw = s.preview.inputId
                    s.preview.inputId = s.program.inputId
                    s.program.inputId = pvw
                    s.program.transition = nil
                } else if pos > 0 {
                    if s.program.transition == nil { s.program.transition = TransitionState(kind: "fade", durationFrames: 0, progress: pos, auto: false) }
                    s.program.transition?.progress = pos
                } else {
                    s.program.transition = nil
                }
            }
            return .object([:])

        case "switcher.ftb":
            let on = p["on"]?.boolValue ?? false
            await store.mutate { $0.program.ftb = on }
            return .object([:])

        case "overlay.set":
            guard let slot = p["slot"]?.intValue, (1...4).contains(slot) else { throw RpcErrorBody.invalidParams("slot 1..4") }
            if let idValue = p["inputId"], case .string(let id) = idValue {
                _ = try await requireInput(.object(["inputId": .string(id)]))
            }
            try await store.mutate { s in
                var o = s.overlays[slot - 1]
                if let idValue = p["inputId"] {
                    if case .string(let id) = idValue { o.inputId = id } else { o.inputId = nil; o.on = false }
                }
                if let on = p["on"]?.boolValue { o.on = on && o.inputId != nil }
                if let r = p["rect"] { o.rect = try Self.decode(Rect.self, r) }
                if let c = p["crop"] { o.crop = try Self.decode(Rect.self, c) }
                if let op = p["opacity"]?.doubleValue { o.opacity = min(1, max(0, op)) }
                if let b = p["border"] { o.border = (b == .null) ? nil : try Self.decode(Border.self, b) }
                if let t = p["transition"] { o.transition = try Self.decode(OverlayTransition.self, t) }
                s.overlays[slot - 1] = o
            }
            return .object([:])

        case "audio.setGain":
            let target = p["inputId"]?.stringValue ?? "master"
            guard let db = p["db"]?.doubleValue else { throw RpcErrorBody.invalidParams("db") }
            let clamped = min(12, max(-60, db))
            if target == "master" {
                await store.mutate { $0.audio.master.db = clamped }
            } else {
                _ = try await requireInput(p)
                await store.mutate { $0.audio.inputs[target]?.db = clamped }
            }
            return .object([:])

        case "audio.setMute", "audio.setSolo", "audio.setAFV":
            let on = p["on"]?.boolValue ?? false
            let target = p["inputId"]?.stringValue ?? "master"
            if target == "master" {
                guard method == "audio.setMute" else { throw RpcErrorBody.invalidParams("inputId") }
                await store.mutate { $0.audio.master.mute = on }
            } else {
                _ = try await requireInput(p)
                await store.mutate { s in
                    switch method {
                    case "audio.setMute": s.audio.inputs[target]?.mute = on
                    case "audio.setSolo": s.audio.inputs[target]?.solo = on
                    default: s.audio.inputs[target]?.afv = on
                    }
                }
            }
            return .object([:])

        case "audio.setDelay":
            let id = try await requireInput(p)
            let ms = min(500, max(-500, p["ms"]?.intValue ?? 0))
            await store.mutate { $0.audio.inputs[id]?.delayMs = ms }
            return .object([:])

        case "audio.setPan":
            let id = try await requireInput(p)
            let pan = min(1, max(-1, p["pan"]?.doubleValue ?? 0))
            await store.mutate { $0.audio.inputs[id]?.pan = pan }
            return .object([:])

        case "audio.setMonitor":
            await store.mutate { s in
                if p["deviceId"] != nil { s.audio.monitor.deviceId = p["deviceId"]?.stringValue }
                if let db = p["db"]?.doubleValue { s.audio.monitor.db = db }
                if let bus = p["bus"]?.stringValue, ["master", "a", "b"].contains(bus) { s.audio.monitor.bus = bus }
            }
            return .object([:])

        case "audio.setBus":
            let id = try await requireInput(p)
            guard let bus = p["bus"]?.stringValue, ["master", "a", "b"].contains(bus) else { throw RpcErrorBody.invalidParams("bus") }
            let on = p["on"]?.boolValue ?? true
            await store.mutate { s in
                var buses = s.audio.inputs[id]?.buses ?? ["master"]
                buses.removeAll { $0 == bus }
                if on { buses.append(bus) }
                s.audio.inputs[id]?.buses = buses
            }
            return .object([:])

        case "audio.setOutputBus":
            guard let target = p["target"]?.stringValue, ["stream", "ndi"].contains(target),
                  let bus = p["bus"]?.stringValue, ["master", "a", "b"].contains(bus) else { throw RpcErrorBody.invalidParams("target/bus") }
            await store.mutate { $0.audio.outputBus[target] = bus }
            return .object([:])

        case "audio.addPlugin":
            let id = try await requireInput(p)
            guard let component = p["componentId"]?.stringValue else { throw RpcErrorBody.invalidParams("componentId") }
            let name = await store.state.devices.audioUnits.first { $0.id == component }?.name ?? component
            let pluginId = "au_" + String(UUID().uuidString.prefix(6)).lowercased()
            // O motor tenta instanciar primeiro; só entra no estado se o AU existir e inicializar.
            try await hooks.inputCommand("audio.ensurePlugin", id, .object(["pluginId": .string(pluginId), "componentId": .string(component)]))
            await store.mutate { $0.audio.inputs[id]?.plugins.append(AudioPluginState(id: pluginId, componentId: component, name: name)) }
            return .object(["pluginId": .string(pluginId)])

        case "audio.removePlugin":
            let id = try await requireInput(p)
            guard let pluginId = p["pluginId"]?.stringValue else { throw RpcErrorBody.invalidParams("pluginId") }
            await store.mutate { $0.audio.inputs[id]?.plugins.removeAll { $0.id == pluginId } }
            try await hooks.inputCommand("audio.removePlugin", id, p)
            return .object([:])

        case "audio.setPluginBypass":
            let id = try await requireInput(p)
            guard let pluginId = p["pluginId"]?.stringValue else { throw RpcErrorBody.invalidParams("pluginId") }
            let on = p["on"]?.boolValue ?? true
            await store.mutate { s in
                guard let i = s.audio.inputs[id]?.plugins.firstIndex(where: { $0.id == pluginId }) else { return }
                s.audio.inputs[id]?.plugins[i].bypass = on
            }
            return .object([:])

        case "audio.openPluginUI":
            let id = try await requireInput(p)
            try await hooks.inputCommand("audio.openPluginUI", id, p)
            return .object([:])

        case "output.add":
            guard let kindRaw = p["kind"]?.stringValue, let kind = OutputKind(rawValue: kindRaw) else { throw RpcErrorBody.invalidParams("kind") }
            if kind == .ndi, !capabilities.ndi { throw RpcErrorBody.domain("CAPABILITY_MISSING", "ndi") }
            if kind == .srt, !capabilities.srt { throw RpcErrorBody.domain("CAPABILITY_MISSING", "srt") }
            let id = "out_" + String(UUID().uuidString.prefix(6)).lowercased()
            let cfg = p["config"] ?? .object([:])
            let name = p["name"]?.stringValue ?? kind.rawValue.uppercased()
            let config = OutputConfig(url: cfg["url"]?.stringValue,
                                      hasStreamKey: cfg["streamKey"]?.stringValue.map { !$0.isEmpty },
                                      ndiName: cfg["ndiName"]?.stringValue,
                                      latencyMs: cfg["latencyMs"]?.intValue)
            if kind == .srt, !(config.url?.hasPrefix("srt://") ?? false) { throw RpcErrorBody.invalidParams("url tem de começar por srt://") }
            // A chave de stream nunca entra no estado; segue para o OutputManager (secrets.json 0600; Keychain na Fase 2).
            await store.mutate { $0.outputs[id] = OutputState(id: id, kind: kind, name: name, config: config) }
            var forward = p.objectValue ?? [:]
            forward["_outputId"] = .string(id)
            try await hooks.outputCommand("output.add", .object(forward))
            return .object(["outputId": .string(id)])

        case "output.update":
            guard let id = p["outputId"]?.stringValue, await store.state.outputs[id] != nil else { throw RpcErrorBody.domain("OUTPUT_NOT_FOUND") }
            await store.mutate { s in
                if let name = p["name"]?.stringValue { s.outputs[id]?.name = name }
                if let ar = p["autoRestart"]?.boolValue { s.outputs[id]?.autoRestart = ar }
                if let cfg = p["config"] {
                    if let url = cfg["url"]?.stringValue { s.outputs[id]?.config.url = url }
                    if let key = cfg["streamKey"]?.stringValue { s.outputs[id]?.config.hasStreamKey = !key.isEmpty }
                    if let n = cfg["ndiName"]?.stringValue { s.outputs[id]?.config.ndiName = n }
                }
            }
            var forward = p.objectValue ?? [:]
            forward["_outputId"] = .string(id)
            try await hooks.outputCommand("output.update", .object(forward))
            return .object([:])

        case "output.remove":
            guard let id = p["outputId"]?.stringValue, let out = await store.state.outputs[id] else { throw RpcErrorBody.domain("OUTPUT_NOT_FOUND") }
            guard out.status == .stopped || out.status == .error else { throw RpcErrorBody.domain("ALREADY_RUNNING", "parar primeiro") }
            await store.mutate { $0.outputs[id] = nil }
            try await hooks.outputCommand("output.remove", p)
            return .object([:])

        case "record.setFolder":
            let folder = p["folder"]?.stringValue
            if let folder, !folder.isEmpty {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else { throw RpcErrorBody.invalidParams("pasta inexistente") }
                guard FileManager.default.isWritableFile(atPath: folder) else { throw RpcErrorBody.domain("PERMISSION_DENIED", "sem permissão de escrita na pasta") }
            }
            await store.mutate { s in
                s.recording.folder = (folder?.isEmpty ?? true) ? nil : folder
                if let c = p["container"]?.stringValue, ["mov", "mp4"].contains(c) { s.recording.container = c }
            }
            return .object([:])

        case "output.start", "output.stop", "record.start", "record.stop":
            try dedupe(p)
            try await hooks.outputCommand(method, p)
            return .object([:])

        case "projector.set":
            await store.mutate { s in
                s.projector.displayId = p["displayId"]?.stringValue
                if let src = p["source"]?.stringValue { s.projector.source = src }
                if let fs = p["fullscreen"]?.boolValue { s.projector.fullscreen = fs }
            }
            return .object([:])

        case "project.setRaster":
            guard let w = p["width"]?.intValue, let h = p["height"]?.intValue, let fps = p["fps"]?.doubleValue else { throw RpcErrorBody.invalidParams("width/height/fps") }
            guard FrameRate(fps: fps) != nil else { throw RpcErrorBody.invalidParams("fps não suportado") }
            let cur = await store.state
            let live = cur.outputs.values.contains { $0.status == .live || $0.status == .starting } || cur.recording.status != "idle"
            guard !live else { throw RpcErrorBody.domain("ALREADY_RUNNING", "parar saídas e gravação antes de mudar o raster") }
            if w >= 3840 && fps > 30 { throw RpcErrorBody.domain("ENCODER_BUDGET", "2160p50/60 não suportado nesta máquina") }
            await store.mutate { $0.project.raster = Raster(width: w, height: h, fps: fps) }
            return .object([:])

        case "project.list":
            guard let dir = projectsDir else { return .array([]) }
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".wtv.json") }.sorted()
            return .array(names.map { .string($0) })

        case "project.save":
            guard let path = p["path"]?.stringValue, !path.isEmpty else { throw RpcErrorBody.invalidParams("path") }
            let url = try projectURL(path)
            var snapshot = await store.state
            snapshot.alarms = []
            do {
                try JSONCoding.encoder.encode(snapshot).write(to: url, options: .atomic)
            } catch { throw RpcErrorBody.domain("INVALID_PARAMS", "não foi possível gravar: \(error.localizedDescription)") }
            let projectName = url.lastPathComponent.replacingOccurrences(of: ".wtv.json", with: "")
            await store.mutate { $0.project.path = url.path; $0.project.name = projectName }
            return .object([:])

        case "project.load":
            guard let path = p["path"]?.stringValue, !path.isEmpty else { throw RpcErrorBody.invalidParams("path") }
            let url = try projectURL(path)
            let loaded: EngineState
            do { loaded = try JSONCoding.decoder.decode(EngineState.self, from: Data(contentsOf: url)) }
            catch { throw RpcErrorBody.domain("INVALID_PARAMS", "projecto ilegível") }
            let cur = await store.state
            let live = cur.outputs.values.contains { $0.status == .live } || cur.recording.status == "recording"
            if live { throw RpcErrorBody.domain("ALREADY_RUNNING", "pare as saídas antes de abrir outro projecto") }
            await store.mutate { s in
                s.project = loaded.project
                s.project.path = url.path
                s.inputs = loaded.inputs
                s.inputOrder = loaded.inputOrder
                for id in s.inputs.keys where s.inputs[id]?.kind != .synthetic { s.inputs[id]?.status = .starting; s.inputs[id]?.media = nil }
                s.program = loaded.program; s.program.transition = nil; s.program.ftb = false
                s.preview = loaded.preview
                s.overlays = loaded.overlays
                s.audio.inputs = loaded.audio.inputs
                s.audio.master = loaded.audio.master
                s.outputs = loaded.outputs
                for id in s.outputs.keys { s.outputs[id]?.status = .stopped; s.outputs[id]?.startedAt = nil; s.outputs[id]?.config.hasStreamKey = false }
                s.multiview.layoutId = loaded.multiview.layoutId
                s.normaliseReferences()
                s.refreshMultiview()
            }
            try await hooks.outputCommand("project.loaded", .object([:]))
            return .object([:])

        case "preview.setLayout":
            guard let layout = p["layoutId"]?.stringValue else { throw RpcErrorBody.invalidParams("layoutId") }
            await store.mutate { s in
                s.multiview.layoutId = layout
                s.multiview.tiles = MultiviewLayouts.tiles(for: layout, inputs: s.inputOrder, names: s.inputs.mapValues(\.name))
            }
            return .object([:])

        case "devices.refresh":
            await hooks.refreshDevices()
            return .object([:])

        case "preview.keyframe":
            return .object([:])

        case "permissions.status":
            return try JSONCoding.tree(await store.state.permissions)

        case "engine.shutdown":
            let force = p["force"]?.boolValue ?? false
            let current = await store.state
            let live = current.outputs.values.contains { $0.status == .live } || current.recording.status == "recording"
            if live && !force { throw RpcErrorBody.domain("ALREADY_RUNNING", "há saídas no ar; use force") }
            await hooks.shutdown(force)
            return .object([:])

        default:
            throw RpcErrorBody.methodNotFound(method)
        }
    }

    private nonisolated static func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        do {
            let data = try JSONCoding.encoder.encode(value)
            return try JSONCoding.decoder.decode(T.self, from: data)
        } catch {
            throw RpcErrorBody.invalidParams("\(T.self): \(error)")
        }
    }

    private func defaultName(for kind: InputKind, _ config: JSONValue) -> String {
        switch kind {
        case .synthetic: return (config["pattern"]?.stringValue ?? "Cor").capitalized
        case .media: return (config["path"]?.stringValue as NSString?)?.lastPathComponent ?? "Ficheiro"
        case .image: return "Imagem"
        case .title: return "Título"
        case .camera: return "Câmara"
        case .screen: return "Ecrã"
        case .ndi: return config["sourceName"]?.stringValue ?? "NDI"
        case .srt: return "SRT"
        case .decklink: return "DeckLink"
        }
    }
}

/// Layouts do multiview partilhados com a UI (rectângulos normalizados).
public enum MultiviewLayouts {
    public static let ids = ["2+8", "2+16", "pgm+pvw"]

    public static func tiles(for layoutId: String, inputs: [InputId], names: [InputId: String]) -> [Tile] {
        var tiles: [Tile] = []
        switch layoutId {
        case "pgm+pvw":
            tiles.append(Tile(source: "preview", rect: Rect(x: 0, y: 0, w: 0.5, h: 1), label: "PREVIEW"))
            tiles.append(Tile(source: "program", rect: Rect(x: 0.5, y: 0, w: 0.5, h: 1), label: "PROGRAM"))
        case "2+16":
            tiles.append(Tile(source: "preview", rect: Rect(x: 0, y: 0, w: 0.5, h: 0.5), label: "PREVIEW"))
            tiles.append(Tile(source: "program", rect: Rect(x: 0.5, y: 0, w: 0.5, h: 0.5), label: "PROGRAM"))
            for (i, id) in inputs.prefix(16).enumerated() {
                let col = Double(i % 8), row = Double(i / 8)
                tiles.append(Tile(source: id, rect: Rect(x: col / 8, y: 0.5 + row * 0.25, w: 1 / 8, h: 0.25), label: names[id] ?? id))
            }
        default: // "2+8"
            tiles.append(Tile(source: "preview", rect: Rect(x: 0, y: 0, w: 0.5, h: 0.5), label: "PREVIEW"))
            tiles.append(Tile(source: "program", rect: Rect(x: 0.5, y: 0, w: 0.5, h: 0.5), label: "PROGRAM"))
            for (i, id) in inputs.prefix(8).enumerated() {
                let col = Double(i % 4), row = Double(i / 4)
                tiles.append(Tile(source: id, rect: Rect(x: col / 4, y: 0.5 + row * 0.25, w: 0.25, h: 0.25), label: names[id] ?? id))
            }
        }
        return tiles
    }
}

extension EngineState {
    /// Remove referências a fontes inexistentes (Program, Preview, overlays, canais de áudio).
    public mutating func normaliseReferences() {
        inputOrder = inputOrder.filter { inputs[$0] != nil }
        for id in inputs.keys where !inputOrder.contains(id) { inputOrder.append(id) }
        if let id = program.inputId, inputs[id] == nil { program.inputId = inputOrder.first }
        if let id = preview.inputId, inputs[id] == nil { preview.inputId = nil }
        for i in overlays.indices {
            if let id = overlays[i].inputId, inputs[id] == nil { overlays[i].inputId = nil; overlays[i].on = false }
        }
        audio.inputs = audio.inputs.filter { inputs[$0.key] != nil }
        for id in inputs.keys where audio.inputs[id] == nil { audio.inputs[id] = AudioChannelState() }
    }

    /// Recalcula os tiles do multiview a partir do layout e das fontes actuais.
    public mutating func refreshMultiview() {
        multiview.tiles = MultiviewLayouts.tiles(for: multiview.layoutId, inputs: inputOrder, names: inputs.mapValues(\.name))
    }
}
