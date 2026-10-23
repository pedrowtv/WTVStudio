import Foundation

/// Identificador JSON-RPC: número ou string.
public enum RpcId: Codable, Sendable, Equatable {
    case number(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "id inválido") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        }
    }
}

public struct RpcRequest: Codable, Sendable {
    public var jsonrpc: String = "2.0"
    public var id: RpcId?
    public var method: String
    public var params: JSONValue?

    public init(id: RpcId?, method: String, params: JSONValue? = nil) {
        self.id = id; self.method = method; self.params = params
    }
}

public struct RpcErrorBody: Codable, Sendable, Error {
    public struct Data: Codable, Sendable {
        public var code: String
        public var detail: String?
        public init(code: String, detail: String? = nil) { self.code = code; self.detail = detail }
    }
    public var code: Int
    public var message: String
    public var data: Data?

    public init(code: Int, message: String, data: Data? = nil) {
        self.code = code; self.message = message; self.data = data
    }

    public static let parseError = RpcErrorBody(code: -32700, message: "parse error")
    public static let invalidRequest = RpcErrorBody(code: -32600, message: "invalid request")
    public static func methodNotFound(_ m: String) -> RpcErrorBody {
        RpcErrorBody(code: -32601, message: "method not found", data: .init(code: "METHOD_NOT_FOUND", detail: m))
    }
    public static func invalidParams(_ detail: String) -> RpcErrorBody {
        RpcErrorBody(code: -32602, message: "invalid params", data: .init(code: "INVALID_PARAMS", detail: detail))
    }
    public static func domain(_ code: String, _ detail: String? = nil) -> RpcErrorBody {
        RpcErrorBody(code: -32000, message: code.lowercased().replacingOccurrences(of: "_", with: " "), data: .init(code: code, detail: detail))
    }
}

public struct RpcResponse: Codable, Sendable {
    public var jsonrpc: String = "2.0"
    public var id: RpcId?
    public var result: JSONValue?
    public var error: RpcErrorBody?

    public init(id: RpcId?, result: JSONValue) { self.id = id; self.result = result }
    public init(id: RpcId?, error: RpcErrorBody) { self.id = id; self.error = error }
}

public struct RpcNotification<P: Codable & Sendable>: Codable, Sendable {
    public var jsonrpc: String = "2.0"
    public var method: String
    public var params: P
    public init(method: String, params: P) { self.method = method; self.params = params }
}

public struct PatchOp: Codable, Sendable, Equatable {
    public var op: String
    public var path: String
    public var value: JSONValue?
    public init(op: String, path: String, value: JSONValue? = nil) { self.op = op; self.path = path; self.value = value }
}

public struct SnapshotParams: Codable, Sendable {
    public var rev: Int
    public var state: EngineState
    public init(rev: Int, state: EngineState) { self.rev = rev; self.state = state }
}

public struct PatchParams: Codable, Sendable {
    public var fromRev: Int
    public var toRev: Int
    public var ops: [PatchOp]
    public init(fromRev: Int, toRev: Int, ops: [PatchOp]) { self.fromRev = fromRev; self.toRev = toRev; self.ops = ops }
}

public struct Capabilities: Codable, Sendable {
    public var ndi: Bool
    public var srt: Bool
    public var decklink: Bool
    public var metalRuntimeShaders: Bool
    public init(ndi: Bool, srt: Bool, decklink: Bool, metalRuntimeShaders: Bool) {
        self.ndi = ndi; self.srt = srt; self.decklink = decklink; self.metalRuntimeShaders = metalRuntimeShaders
    }
}

public struct HelloResult: Codable, Sendable {
    public var protocolVersion: Int
    public var engineVersion: String
    public var capabilities: Capabilities
    public var snapshot: SnapshotParams
    public init(protocolVersion: Int, engineVersion: String, capabilities: Capabilities, snapshot: SnapshotParams) {
        self.protocolVersion = protocolVersion; self.engineVersion = engineVersion
        self.capabilities = capabilities; self.snapshot = snapshot
    }
}

public struct LogParams: Codable, Sendable {
    public var level: String
    public var code: String
    public var message: String
    public var at: Date
    public init(level: String, code: String, message: String, at: Date = Date()) {
        self.level = level; self.code = code; self.message = message; self.at = at
    }
}
