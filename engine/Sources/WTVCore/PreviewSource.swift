import Foundation

/// O que o servidor precisa do motor de vídeo para servir /ws/preview e /api/snapshot.png.
public protocol PreviewSource: Sendable {
    /// Subscreve um stream ("multiview" ou "program"). Devolve nil se não existir.
    func subscribe(stream: String) -> (UUID, AsyncStream<Data>)?
    func unsubscribe(_ id: UUID)
    /// PNG do bus pedido ("program", "preview", "multiview") ou nil.
    func snapshotPNG(bus: String) -> Data?
}

/// Cabeçalho binário dos frames de preview (docs/PROTOCOLO.md §5). 24 bytes, little-endian.
public enum PreviewFrame {
    public static let headerSize = 24
    public static let magic: [UInt8] = [0x57, 0x54, 0x56, 0x46] // "WTVF"
    public static let version: UInt8 = 1

    public enum Stream: UInt8 { case multiview = 1, program = 2, meters = 16, mediaPositions = 17 }
    public enum Codec: UInt8 { case none = 0, avc1 = 1, hvc1 = 2, jpeg = 3 }
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let keyframe = Flags(rawValue: 1 << 0)
        public static let hasConfig = Flags(rawValue: 1 << 1)
        public static let discontinuity = Flags(rawValue: 1 << 2)
    }

    /// Monta a mensagem completa: cabeçalho + (u16 configLen + config)? + payload.
    public static func encode(stream: Stream, flags: Flags, codec: Codec, seq: UInt32, ptsMicros: UInt64, config: Data?, payload: Data) -> Data {
        var f = flags
        var body = Data()
        if let config {
            f.insert(.hasConfig)
            var len = UInt16(config.count).littleEndian
            body.append(Data(bytes: &len, count: 2))
            body.append(config)
        }
        body.append(payload)
        var out = Data(capacity: headerSize + body.count)
        out.append(contentsOf: magic)
        out.append(version)
        out.append(stream.rawValue)
        out.append(f.rawValue)
        out.append(codec.rawValue)
        var s = seq.littleEndian; out.append(Data(bytes: &s, count: 4))
        var p = ptsMicros.littleEndian; out.append(Data(bytes: &p, count: 8))
        var l = UInt32(body.count).littleEndian; out.append(Data(bytes: &l, count: 4))
        out.append(body)
        return out
    }
}
