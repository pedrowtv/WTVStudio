import Foundation
import Testing
import WTVCore
import WTVProtocol

private func makeState() -> EngineState {
    EngineState(system: SystemState(engineVersion: "t", pid: 1, startedAt: Date(timeIntervalSince1970: 0), bind: "127.0.0.1:7420", remoteAccess: false))
}

@Suite struct JSONDiffTests {
    @Test func objectDiff() {
        let a: JSONValue = .object(["x": .number(1), "y": .object(["z": .string("a")]), "gone": .bool(true)])
        let b: JSONValue = .object(["x": .number(2), "y": .object(["z": .string("a"), "w": .null]), "new": .array([.number(1)])])
        let ops = JSONDiff.diff(a, b)
        #expect(ops.contains(PatchOp(op: "remove", path: "/gone")))
        #expect(ops.contains(PatchOp(op: "replace", path: "/x", value: .number(2))))
        #expect(ops.contains(PatchOp(op: "add", path: "/y/w", value: .null)))
        #expect(ops.contains(PatchOp(op: "add", path: "/new", value: .array([.number(1)]))))
        #expect(ops.count == 4)
    }

    @Test func escapesKeys() {
        let ops = JSONDiff.diff(.object([:]), .object(["a/b~c": .number(1)]))
        #expect(ops == [PatchOp(op: "add", path: "/a~1b~0c", value: .number(1))])
    }
}

@Suite struct StateStoreTests {
    @Test func mutateIncrementsRevAndEmitsPatch() async throws {
        let store = try StateStore(initial: makeState())
        let (id, stream) = await store.subscribe()
        let rev = await store.mutate { $0.project.name = "Teste" }
        #expect(rev == 1)
        var iterator = stream.makeAsyncIterator()
        let patch = await iterator.next()
        #expect(patch?.fromRev == 0 && patch?.toRev == 1)
        #expect(patch?.ops.contains(PatchOp(op: "replace", path: "/project/name", value: .string("Teste"))) == true)
        #expect(patch?.ops.contains(PatchOp(op: "replace", path: "/rev", value: .number(1))) == true)
        await store.unsubscribe(id)
    }

    @Test func noopMutationKeepsRev() async throws {
        let store = try StateStore(initial: makeState())
        let rev = await store.mutate { _ in }
        #expect(rev == 0)
    }

    @Test func patchesSince() async throws {
        let store = try StateStore(initial: makeState())
        await store.mutate { $0.project.name = "a" }
        await store.mutate { $0.project.name = "b" }
        let all = await store.patches(since: 0)
        #expect(all?.count == 2)
        let one = await store.patches(since: 1)
        #expect(one?.count == 1)
        let none = await store.patches(since: 2)
        #expect(none?.isEmpty == true)
    }
}

@Suite struct CommandRouterTests {
    private func makeRouter() async throws -> CommandRouter {
        let store = try StateStore(initial: makeState())
        return CommandRouter(store: store, capabilities: Capabilities(ndi: false, srt: false, decklink: false, metalRuntimeShaders: true),
                             engineVersion: "t", hooks: .init(shutdown: { _ in }))
    }

    @Test func helloReturnsSnapshot() async throws {
        let router = try await makeRouter()
        let resp = await router.handle(RpcRequest(id: .number(1), method: "session.hello", params: .object(["clientKind": .string("browser"), "clientName": .string("t")])))
        #expect(resp.error == nil)
        #expect(resp.result?["protocolVersion"]?.intValue == protocolVersion)
        #expect(resp.result?["snapshot"]?["rev"]?.intValue == 0)
    }

    @Test func addInputsAndCut() async throws {
        let router = try await makeRouter()
        let a = await router.handle(RpcRequest(id: .number(1), method: "input.add", params: .object(["kind": .string("synthetic"), "config": .object(["pattern": .string("bars")])])))
        let b = await router.handle(RpcRequest(id: .number(2), method: "input.add", params: .object(["kind": .string("synthetic"), "config": .object(["pattern": .string("colour")])])))
        let idA = try #require(a.result?["inputId"]?.stringValue)
        let idB = try #require(b.result?["inputId"]?.stringValue)
        var state = await router.store.state
        #expect(state.program.inputId == idA)
        #expect(state.preview.inputId == idB)
        #expect(state.inputs[idA]?.name == "Bars")

        let cut = await router.handle(RpcRequest(id: .number(3), method: "switcher.cut", params: .object(["txnId": .string("t1")])))
        #expect(cut.error == nil)
        state = await router.store.state
        #expect(state.program.inputId == idB)
        #expect(state.preview.inputId == idA)

        // Repetição do mesmo txnId (reconexão): devolve o resultado guardado sem executar outra vez
        let dup = await router.handle(RpcRequest(id: .number(4), method: "switcher.cut", params: .object(["txnId": .string("t1")])))
        #expect(dup.error == nil)
        let after = await router.store.state
        #expect(after.program.inputId == idB) // não voltou a trocar
    }

    @Test func unknownMethodAndMissingInput() async throws {
        let router = try await makeRouter()
        let r1 = await router.handle(RpcRequest(id: .number(1), method: "nope"))
        #expect(r1.error?.code == -32601)
        let r2 = await router.handle(RpcRequest(id: .number(2), method: "switcher.setPreview", params: .object(["inputId": .string("in_x")])))
        #expect(r2.error?.data?.code == "INPUT_NOT_FOUND")
    }

    @Test func rasterGuard() async throws {
        let router = try await makeRouter()
        let bad = await router.handle(RpcRequest(id: .number(1), method: "project.setRaster", params: .object(["width": .number(3840), "height": .number(2160), "fps": .number(60)])))
        #expect(bad.error?.data?.code == "ENCODER_BUDGET")
        let ok = await router.handle(RpcRequest(id: .number(2), method: "project.setRaster", params: .object(["width": .number(1920), "height": .number(1080), "fps": .number(59.94)])))
        #expect(ok.error == nil)
        #expect(await router.store.state.project.raster.fps == 59.94)
    }
}
