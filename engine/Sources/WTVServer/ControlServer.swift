import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging
import NIOCore
import WTVCore
import WTVProtocol

/// HTTP + WebSocket do motor (docs/PROTOCOLO.md §1). Serve a UI, /api/* e /ws/control.
/// /ws/preview chega com o compositor (passo 4).
public struct ControlServer: Sendable {
    public struct Config: Sendable {
        public var host: String
        public var port: Int
        public var token: String?
        public var uiDirectory: String?
        public init(host: String, port: Int, token: String?, uiDirectory: String?) {
            self.host = host; self.port = port; self.token = token; self.uiDirectory = uiDirectory
        }
    }

    let config: Config
    let router: CommandRouter
    let store: StateStore
    let preview: PreviewSource?
    let sessions = SessionTable()
    let log = Logger(label: "wtv.server")

    public init(config: Config, router: CommandRouter, store: StateStore, preview: PreviewSource? = nil) {
        self.config = config
        self.router = router
        self.store = store
        self.preview = preview
    }

    public func run() async throws {
        let http = Router(context: BasicWebSocketRequestContext.self)
        http.middlewares.add(CORSMiddleware(allowOrigin: .custom("http://localhost:5173"), allowHeaders: [.contentType, .authorization], allowMethods: [.get, .post, .put, .options]))

        http.get("/api/health") { _, _ in
            let state = await store.state
            return JSONBody(["ok": .bool(true), "version": .string(state.system.engineVersion),
                             "uptimeSeconds": .number(Date().timeIntervalSince(state.system.startedAt))])
        }

        // Troca o token por um cookie HttpOnly (docs/PROTOCOLO.md §1, D21).
        http.post("/api/session") { request, context -> Response in
            guard let token = config.token else { return try JSONBody(["ok": .bool(true), "dev": .bool(true)]).response(from: request, context: context) }
            struct Body: Decodable { var token: String? }
            let body = try? await request.decode(as: Body.self, context: context)
            let given = body?.token ?? request.headers[.authorization]?.replacingOccurrences(of: "Bearer ", with: "")
            guard let given, SessionTable.constantTimeEquals(given, token) else { throw HTTPError(.unauthorized) }
            let sid = sessions.create()
            var response = try JSONBody(["ok": .bool(true)]).response(from: request, context: context)
            response.headers[.setCookie] = "wtv_session=\(sid); Path=/; HttpOnly; SameSite=Strict"
            return response
        }

        http.get("/api/hello") { request, _ in
            try authorize(request)
            let state = await store.state
            return JSONBody(["protocolVersion": .number(Double(protocolVersion)),
                             "engineVersion": .string(state.system.engineVersion),
                             "capabilities": try JSONCoding.tree(router.capabilities),
                             "bind": .string(state.system.bind)])
        }

        http.get("/api/state") { request, _ in
            try authorize(request)
            return JSONBody(try JSONCoding.tree(await store.snapshot()))
        }

        http.get("/api/snapshot.png") { request, _ in
            try authorize(request)
            let bus = request.uri.queryParameters["bus"].map(String.init) ?? "program"
            guard let png = preview?.snapshotPNG(bus: bus) else { throw HTTPError(.notFound) }
            return Response(status: .ok, headers: [.contentType: "image/png"], body: .init(byteBuffer: ByteBuffer(data: png)))
        }

        http.ws("/ws/preview", shouldUpgrade: { request, _ in
            guard originAllowed(request) else { return .dontUpgrade }
            do {
                try authorize(request)
                return .upgrade([:])
            } catch {
                return .dontUpgrade
            }
        }, onUpgrade: { inbound, outbound, context in
            let stream = context.request.uri.queryParameters["stream"].map(String.init) ?? "multiview"
            await handlePreview(stream: stream, inbound: inbound, outbound: outbound)
        })

        if let dir = config.uiDirectory {
            http.add(middleware: FileMiddleware(dir, searchForIndexHtml: true))
        }

        http.ws("/ws/control", shouldUpgrade: { request, _ in
            guard originAllowed(request) else { log.warning("upgrade recusado: Origin \(request.headers[.origin] ?? "?")"); return .dontUpgrade }
            do {
                try authorize(request)
                return .upgrade([:])
            } catch {
                return .dontUpgrade
            }
        }, onUpgrade: { inbound, outbound, _ in
            await handleControl(inbound: inbound, outbound: outbound)
        })

        let app = Application(
            router: http,
            server: .http1WebSocketUpgrade(webSocketRouter: http),
            configuration: .init(address: .hostname(config.host, port: config.port), serverName: "wtv-engine")
        )
        log.info("a escutar em http://\(config.host):\(config.port)")
        try await app.runService()
    }

    // MARK: - Auth

    func authorize(_ request: Request) throws {
        guard let token = config.token else { return } // modo --dev sem token (só loopback; ver Engine.swift)
        if let auth = request.headers[.authorization], SessionTable.constantTimeEquals(auth, "Bearer \(token)") { return }
        if let sid = SessionTable.cookie(named: "wtv_session", in: request.headers[.cookie]), sessions.isValid(sid) { return }
        throw HTTPError(.unauthorized)
    }

    /// Browsers enviam Origin nos upgrades WebSocket: só aceita a própria origem (UI servida pelo motor),
    /// o servidor Vite em desenvolvimento, ou ausência de Origin (clientes não-browser, ex.: scripts).
    func originAllowed(_ request: Request) -> Bool {
        guard let origin = request.headers[.origin] else { return true }
        if origin == "null" { return false }
        guard let url = URL(string: origin), let host = url.host else { return false }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        if ["localhost", "127.0.0.1", "::1"].contains(host) && [5173, 5174].contains(port) { return true }
        if let reqHost = request.head.authority {
            // Host: "127.0.0.1:7420" ou "mac.local:7420"
            let parts = reqHost.split(separator: ":")
            let rh = parts.count >= 1 ? String(parts[0]) : ""
            let rp = parts.count == 2 ? Int(parts[1]) ?? config.port : config.port
            if host.lowercased() == rh.lowercased() && port == rp { return true }
        }
        return false
    }

    // MARK: - WebSocket de controlo

    func handleControl(inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter) async {
        let (subId, patches) = await store.subscribe()
        defer { Task { await store.unsubscribe(subId) } }
        log.info("cliente de controlo ligado")

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await patch in patches {
                    guard let text = try? JSONCoding.string(RpcNotification(method: "state.patch", params: patch)) else { continue }
                    do { try await outbound.write(.text(text)) } catch { break }
                }
            }
            group.addTask {
                do {
                    for try await message in inbound.messages(maxSize: 1 << 20) {
                        guard case .text(let text) = message else { continue }
                        let reply = await self.process(text)
                        try await outbound.write(.text(reply))
                    }
                } catch {
                    self.log.debug("controlo terminou: \(error)")
                }
            }
            await group.next()
            group.cancelAll()
        }
        log.info("cliente de controlo desligado")
    }

    // MARK: - WebSocket de preview (binário)

    func handlePreview(stream: String, inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter) async {
        guard let preview, let (id, frames) = preview.subscribe(stream: stream) else {
            log.warning("preview: stream desconhecido \(stream)")
            return
        }
        defer { preview.unsubscribe(id) }
        log.info("cliente de preview ligado (\(stream))")
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await data in frames {
                    do { try await outbound.write(.binary(ByteBuffer(data: data))) } catch { break }
                }
            }
            group.addTask {
                do { for try await _ in inbound.messages(maxSize: 1 << 16) {} } catch {}
            }
            await group.next()
            group.cancelAll()
        }
        log.info("cliente de preview desligado (\(stream))")
    }

    func process(_ text: String) async -> String {
        let request: RpcRequest
        do {
            request = try JSONCoding.decoder.decode(RpcRequest.self, from: Data(text.utf8))
        } catch {
            return (try? JSONCoding.string(RpcResponse(id: nil, error: .parseError))) ?? "{}"
        }
        guard request.jsonrpc == "2.0" else {
            return (try? JSONCoding.string(RpcResponse(id: request.id, error: .invalidRequest))) ?? "{}"
        }
        let response = await router.handle(request)
        return (try? JSONCoding.string(response)) ?? "{}"
    }
}

/// Corpo JSON a partir de uma árvore `JSONValue`.
struct JSONBody: ResponseGenerator {
    let value: JSONValue
    init(_ dict: [String: JSONValue]) { value = .object(dict) }
    init(_ value: JSONValue) { self.value = value }

    func response(from request: Request, context: some RequestContext) throws -> Response {
        let data = try JSONCoding.encoder.encode(value)
        return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(data: data)))
    }
}

/// Sessões de cookie: identificadores aleatórios mapeados para o token (o token nunca viaja em cookies nem em URLs).
public final class SessionTable: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var ids = Set<String>()

    public init() {}

    public func create() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let id = bytes.map { String(format: "%02x", $0) }.joined()
        os_unfair_lock_lock(&lock); ids.insert(id); os_unfair_lock_unlock(&lock)
        return id
    }

    public func isValid(_ id: String) -> Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return ids.contains(id)
    }

    public static func cookie(named name: String, in header: String?) -> String? {
        guard let header else { return nil }
        for part in header.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == name[...] { return String(kv[1]) }
        }
        return nil
    }

    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
