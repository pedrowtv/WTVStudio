import Foundation
import Logging
import WTVProtocol

/// Única fonte de verdade do estado (D5). Cada mutação incrementa `rev` e emite um JSON Patch.
public actor StateStore {
    public private(set) var state: EngineState
    private var tree: JSONValue
    private var subscribers: [UUID: AsyncStream<PatchParams>.Continuation] = [:]
    private var patchRing: [PatchParams] = []
    private let patchRingLimit = 2000
    private var onChange: (@Sendable (EngineState) -> Void)?
    private let log = Logger(label: "wtv.state")

    public init(initial: EngineState) throws {
        state = initial
        tree = try JSONCoding.tree(initial)
    }

    public func setOnChange(_ handler: @escaping @Sendable (EngineState) -> Void) {
        onChange = handler
    }

    public var rev: Int { state.rev }

    public func snapshot() -> SnapshotParams {
        SnapshotParams(rev: state.rev, state: state)
    }

    /// Aplica uma mutação; devolve a nova revisão. Mutações que não alteram nada não incrementam `rev`.
    @discardableResult
    public func mutate(_ body: (inout EngineState) throws -> Void) rethrows -> Int {
        var next = state
        try body(&next)
        if next == state { return state.rev }
        next.rev = state.rev + 1
        let nextTree: JSONValue
        do {
            nextTree = try JSONCoding.tree(next)
        } catch {
            log.error("falha a serializar estado: \(error)")
            return state.rev
        }
        let ops = JSONDiff.diff(tree, nextTree)
        let patch = PatchParams(fromRev: state.rev, toRev: next.rev, ops: ops)
        state = next
        tree = nextTree
        patchRing.append(patch)
        if patchRing.count > patchRingLimit { patchRing.removeFirst(patchRing.count - patchRingLimit) }
        for (_, c) in subscribers { c.yield(patch) }
        onChange?(next)
        return next.rev
    }

    /// Patches desde `rev` (exclusivo), ou nil se a lacuna for demasiado antiga.
    public func patches(since rev: Int) -> [PatchParams]? {
        if rev > state.rev { return nil } // cliente com revisão de um motor anterior: snapshot
        guard let first = patchRing.first, first.fromRev <= rev else {
            return rev == state.rev ? [] : nil
        }
        return patchRing.filter { $0.fromRev >= rev }
    }

    public func subscribe() -> (UUID, AsyncStream<PatchParams>) {
        let id = UUID()
        let stream = AsyncStream<PatchParams> { continuation in
            subscribers[id] = continuation
        }
        return (id, stream)
    }

    public func unsubscribe(_ id: UUID) {
        subscribers[id]?.finish()
        subscribers[id] = nil
    }

    public var subscriberCount: Int { subscribers.count }
}
