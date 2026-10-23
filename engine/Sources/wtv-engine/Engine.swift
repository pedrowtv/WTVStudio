import AppKit
import ArgumentParser
import Foundation
import Logging
import WTVCore
import WTVOutputs
import WTVProtocol
import WTVServer

let engineVersion = "0.1.0"

@main
struct EngineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wtv-engine",
        abstract: "Motor de vídeo do WTV Studio (docs/ARQUITECTURA.md)."
    )

    @Option(name: .long, help: "Porta HTTP/WebSocket.") var port: Int = defaultPort
    @Option(name: .long, help: "Endereço a escutar (127.0.0.1 ou 0.0.0.0).") var bind: String = "127.0.0.1"
    @Option(name: .long, help: "Pasta de dados (por omissão ~/Library/Application Support/WTV Studio).") var dataDir: String?
    @Option(name: .long, help: "Pasta com a UI construída para servir em /.") var ui: String?
    @Flag(name: .long, help: "Desenvolvimento: sem token, não escreve engine.json.") var dev = false
    @Flag(name: .long, help: "Sem janelas (testes).") var headless = false
    @Option(name: .long, help: "Nível de log: trace, debug, info, warning, error.") var logLevel: String = "info"

    func run() async throws {
        let level = Logger.Level(rawValue: logLevel) ?? .info
        let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/WTV Studio/engine.log")
        let sink = FileLogHandler.FileSink(url: dev ? nil : logURL, alsoStderr: true)
        LoggingSystem.bootstrap { label in FileLogHandler(label: label, level: level, sink: sink) }
        let log = Logger(label: "wtv.engine")

        if dev && bind != "127.0.0.1" && bind != "localhost" {
            log.error("--dev (sem token) só é permitido em loopback; use --bind 127.0.0.1 ou retire --dev")
            throw ExitCode(2)
        }
        let files = try EngineFiles(dataDir: dataDir.map { URL(fileURLWithPath: $0) })
        guard let lockFD = files.acquireLock() else {
            log.error("já existe um motor a correr (engine.lock). Saída.")
            throw ExitCode(2)
        }
        defer { close(lockFD) }

        let system = SystemState(engineVersion: engineVersion, pid: Int(getpid()), startedAt: Date(),
                                 bind: "\(bind):\(port)", remoteAccess: bind != "127.0.0.1")
        var initial = files.loadSession() ?? EngineState(system: system)
        initial.system = system
        initial.rev = 0
        // Nunca retomar saídas automaticamente sem autoRestart (D19).
        for id in initial.outputs.keys {
            initial.outputs[id]?.status = .stopped
            initial.outputs[id]?.startedAt = nil
        }
        let keepFolder = initial.recording.folder, keepContainer = initial.recording.container
        initial.recording = RecordingState()
        initial.recording.folder = keepFolder
        initial.recording.container = keepContainer
        initial.alarms = []
        initial.devices = Devices()
        initial.normaliseReferences()
        for id in initial.inputs.keys where initial.inputs[id]?.kind != .synthetic {
            initial.inputs[id]?.status = .starting
        }
        initial.refreshMultiview()

        let store = try StateStore(initial: initial)
        let saver = SessionSaver(files: files)
        await store.setOnChange { state in Task { await saver.schedule(state) } }

        // O porto tem de estar livre antes de anunciar engine.json (senão fica um ficheiro órfão a apontar para outro processo).
        guard EngineCommand.portIsFree(host: bind, port: port) else {
            log.error("o porto \(port) já está em uso")
            throw ExitCode(3)
        }
        let token: String? = dev ? nil : files.loadOrCreateToken()
        if let token {
            try files.writeEngineInfo(.init(pid: Int(getpid()), port: port, token: token, version: engineVersion, startedAt: Date()))
        }

        let capabilities = Capabilities(ndi: NDIRuntime.shared.load(), srt: true, decklink: false, metalRuntimeShaders: true)
        let video: VideoEngine?
        do {
            video = try await VideoEngine(store: store)
        } catch {
            log.error("motor de vídeo indisponível: \(error)")
            video = nil
        }
        let inputs: InputManager? = video.map { InputManager(store: store, frames: $0.frames, mixer: $0.mixer) }
        let outputs: OutputManager? = video.map { OutputManager(store: store, mixer: $0.mixer, files: files, device: $0.metal.device) }
        video?.outputs = outputs
        if !headless {
            // AppKit para a janela do projector (sem Dock, sem menu). O ciclo de eventos corre no fim de run().
            await MainActor.run {
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                app.finishLaunching()
            }
        }
        let router = CommandRouter(store: store, capabilities: capabilities, engineVersion: engineVersion,
                                   hooks: .init(shutdown: { _ in
                                       await saver.flush()
                                       files.removeEngineInfo()
                                       Foundation.exit(0)
                                   }, animatesTransitions: video != nil,
                                   inputCommand: { name, id, params in try await inputs?.command(name, inputId: id, params: params) },
                                   refreshDevices: { await inputs?.refreshDevices() },
                                   outputCommand: { method, params in try await outputs?.command(method, params: params) }))
        await router.setProjectsDir(files.projectsDir)
        await video?.start()
        await inputs?.start()
        await outputs?.start()

        // UI: --ui, senão Contents/Resources/ui do bundle (quando corre como WTV Engine.app).
        var uiDir = ui
        if uiDir == nil, let res = Bundle.main.resourceURL?.appendingPathComponent("ui", isDirectory: true),
           FileManager.default.fileExists(atPath: res.appendingPathComponent("index.html").path) {
            uiDir = res.path
        }
        if let uiDir { log.info("UI servida de \(uiDir)") }
        let server = ControlServer(config: .init(host: bind, port: port, token: token, uiDirectory: uiDir), router: router, store: store, preview: video)
        log.info("WTV Engine \(engineVersion) pid \(getpid()) dados em \(files.dataDir.path)\(dev ? " [dev]" : "")")

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT)
        signal(SIGINT, SIG_IGN)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM)
        signal(SIGTERM, SIG_IGN)
        for src in [sigint, sigterm] {
            src.setEventHandler {
                Task {
                    await saver.flush()
                    files.removeEngineInfo()
                    Foundation.exit(0)
                }
            }
            src.resume()
        }

        if headless {
            do { try await server.run() } catch { files.removeEngineInfo(); throw error }
            return
        }
        // O servidor corre fora da main thread; a main thread fica com o ciclo de eventos do AppKit,
        // sem o qual as janelas (projector) não respondem a cliques nem ao teclado.
        let serverTask = Task.detached {
            do { try await server.run() } catch {
                log.error("servidor terminou: \(error)")
                files.removeEngineInfo()
                Foundation.exit(4)
            }
        }
        _ = serverTask
        await MainActor.run { NSApplication.shared.run() }
    }

    /// Tenta abrir um socket de escuta no porto; devolve true se estiver livre.
    static func portIsFree(host: String, port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = (host == "0.0.0.0") ? INADDR_ANY : inet_addr(host == "localhost" ? "127.0.0.1" : host)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        return rc == 0
    }
}
