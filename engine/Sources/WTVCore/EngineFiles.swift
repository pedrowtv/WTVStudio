import Foundation
import Logging
import WTVProtocol

/// Ficheiros em ~/Library/Application Support/WTV Studio (docs/PROTOCOLO.md §6).
public struct EngineFiles: Sendable {
    public let dataDir: URL
    private let log = Logger(label: "wtv.files")

    public init(dataDir: URL? = nil) throws {
        let base = dataDir ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WTV Studio", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.dataDir = base
    }

    public var engineJSON: URL { dataDir.appendingPathComponent("engine.json") }
    public var sessionJSON: URL { dataDir.appendingPathComponent("session.json") }
    public var lockFile: URL { dataDir.appendingPathComponent("engine.lock") }
    public var projectsDir: URL { dataDir.appendingPathComponent("projects", isDirectory: true) }

    public struct EngineInfo: Codable, Sendable {
        public var pid: Int
        public var port: Int
        public var token: String
        public var version: String
        public var startedAt: Date
        public init(pid: Int, port: Int, token: String, version: String, startedAt: Date) {
            self.pid = pid; self.port = port; self.token = token; self.version = version; self.startedAt = startedAt
        }
    }

    /// Token novo a cada arranque (D21): quem se liga lê-o de engine.json; um token antigo que tenha fugido morre com o processo.
    public func loadOrCreateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public func writeEngineInfo(_ info: EngineInfo) throws {
        let data = try JSONCoding.encoder.encode(info)
        try data.write(to: engineJSON, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: engineJSON.path)
    }

    public func removeEngineInfo() {
        try? FileManager.default.removeItem(at: engineJSON)
    }

    public func loadSession() -> EngineState? {
        guard let data = try? Data(contentsOf: sessionJSON) else { return nil }
        do {
            return try JSONCoding.decoder.decode(EngineState.self, from: data)
        } catch {
            log.warning("session.json ilegível, a ignorar: \(error)")
            return nil
        }
    }

    public func saveSession(_ state: EngineState) {
        do {
            let data = try JSONCoding.encoder.encode(state)
            try data.write(to: sessionJSON, options: .atomic)
        } catch {
            log.error("falha a gravar session.json: \(error)")
        }
    }

    /// Instância única por utilizador. Devolve o descritor para manter o lock vivo.
    public func acquireLock() -> Int32? {
        let fd = open(lockFile.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        return fd
    }
}

/// Gravação da sessão com debounce de 500 ms (D19).
public actor SessionSaver {
    private let files: EngineFiles
    private var pending: EngineState?
    private var task: Task<Void, Never>?

    public init(files: EngineFiles) { self.files = files }

    public func schedule(_ state: EngineState) {
        pending = state
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    public func flush() {
        guard let s = pending else { return }
        pending = nil
        files.saveSession(s)
    }
}
