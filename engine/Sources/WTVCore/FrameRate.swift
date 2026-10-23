import Foundation

/// Cadência de frames como duração racional exacta (D6 em docs/ARQUITECTURA.md).
/// 59.94 → 1001/60000 s; 29.97 → 1001/30000 s; 50 → 1/50 s.
public struct FrameRate: Sendable, Equatable, Hashable {
    /// Numerador e denominador da DURAÇÃO de um frame em segundos.
    public let durationNum: Int64
    public let durationDen: Int64

    public init?(fps: Double) {
        switch fps {
        case 25: self.init(num: 1, den: 25)
        case 29.97: self.init(num: 1001, den: 30000)
        case 30: self.init(num: 1, den: 30)
        case 50: self.init(num: 1, den: 50)
        case 59.94: self.init(num: 1001, den: 60000)
        case 60: self.init(num: 1, den: 60)
        default: return nil
        }
    }

    public init(num: Int64, den: Int64) {
        durationNum = num
        durationDen = den
    }

    public var fps: Double { Double(durationDen) / Double(durationNum) }

    /// Instante do tick N em nanossegundos a partir da origem, sem acumulação de erro.
    public func tickNanos(_ n: Int64) -> Int64 {
        // n * num * 1e9 / den, em inteiros de 128 bits para não transbordar
        let (hi, lo) = n.multipliedFullWidth(by: durationNum * 1_000_000_000)
        let (q, _) = durationDen.dividingFullWidth((hi, lo))
        return q
    }

    /// Índice da amostra de áudio (48 kHz) que coincide com o tick N. Exacto: 59.94 → 4004 amostras por 5 frames.
    public func sampleIndex(forTick n: Int64, sampleRate: Int64 = 48000) -> Int64 {
        (n * durationNum * sampleRate) / durationDen
    }

    /// Número do tick que contém o instante dado (nanossegundos desde a origem).
    public func tick(atNanos t: Int64) -> Int64 {
        let (hi, lo) = t.multipliedFullWidth(by: durationDen)
        let (q, _) = (durationNum * 1_000_000_000).dividingFullWidth((hi, lo))
        return q
    }
}
