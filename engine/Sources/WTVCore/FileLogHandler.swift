import Foundation
import Logging

/// LogHandler que escreve em stderr e num ficheiro (docs/PROTOCOLO.md §6: ~/Library/Logs/WTV Studio/engine.log).
/// Sob `open`/launchd o stderr não é capturado, por isso o ficheiro é o registo de referência.
public struct FileLogHandler: LogHandler {
    public var logLevel: Logger.Level
    public var metadata: Logger.Metadata = [:]
    private let label: String
    private let sink: FileSink

    public init(label: String, level: Logger.Level, sink: FileSink) {
        self.label = label
        logLevel = level
        self.sink = sink
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
        let stamp = FileSink.formatter.string(from: Date())
        let line = "\(stamp) \(level) \(label): \(message)\n"
        sink.write(line)
    }

    /// Destino partilhado por todos os loggers (um ficheiro aberto, escrita serializada).
    public final class FileSink: @unchecked Sendable {
        nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        private let handle: FileHandle?
        private let queue = DispatchQueue(label: "wtv.log")
        private let alsoStderr: Bool

        public init(url: URL?, alsoStderr: Bool) {
            self.alsoStderr = alsoStderr
            if let url {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                // roda quando passa de 20 MB
                if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 20_000_000 {
                    try? FileManager.default.removeItem(at: url.appendingPathExtension("1"))
                    try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("1"))
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: url)
                handle?.seekToEndOfFile()
            } else {
                handle = nil
            }
        }

        func write(_ s: String) {
            let data = Data(s.utf8)
            if alsoStderr { FileHandle.standardError.write(data) }
            queue.async { [handle] in handle?.write(data) }
        }
    }
}
