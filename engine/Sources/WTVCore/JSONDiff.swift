import Foundation
import WTVProtocol

/// Calcula um JSON Patch (add/replace/remove) entre duas árvores. Arrays diferentes são substituídos por inteiro.
public enum JSONDiff {
    public static func diff(_ a: JSONValue, _ b: JSONValue) -> [PatchOp] {
        var ops: [PatchOp] = []
        walk(a, b, path: "", into: &ops)
        return ops
    }

    private static func escape(_ key: String) -> String {
        key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    private static func walk(_ a: JSONValue, _ b: JSONValue, path: String, into ops: inout [PatchOp]) {
        if a == b { return }
        switch (a, b) {
        case (.object(let oa), .object(let ob)):
            for key in oa.keys.sorted() where ob[key] == nil {
                ops.append(PatchOp(op: "remove", path: path + "/" + escape(key)))
            }
            for key in ob.keys.sorted() {
                let child = path + "/" + escape(key)
                if let va = oa[key] {
                    walk(va, ob[key]!, path: child, into: &ops)
                } else {
                    ops.append(PatchOp(op: "add", path: child, value: ob[key]!))
                }
            }
        default:
            ops.append(PatchOp(op: path.isEmpty ? "replace" : "replace", path: path, value: b))
        }
    }
}
