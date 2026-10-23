import CoreVideo
import Foundation
import WTVProtocol

/// O que desenhar num tick. Imutável; construído a partir do EngineState na camada de controlo
/// e lido pela thread de vídeo (D5/D6).
public struct RenderPlan: Sendable {
    public struct Layer: Sendable {
        public enum Source: Sendable {
            case input(InputId)
            case bus(Bus)
        }
        public var source: Source
        public var rect: Rect
        public var crop: Rect
        public var opacity: Double
        public init(source: Source, rect: Rect = .full, crop: Rect = .full, opacity: Double = 1) {
            self.source = source; self.rect = rect; self.crop = crop; self.opacity = opacity
        }
    }

    public enum Bus: Sendable { case program, preview, multiview }

    public struct Transition: Sendable {
        public var kind: String          // fade, wipe, dip
        public var durationFrames: Int
        public var auto: Bool
        public var manualProgress: Double
        public var wipeDirection: String
        public var wipeSoftness: Double
        public var colour: SIMD4<Float>
        public var toInput: InputId?
    }

    public struct InputSpec: Sendable {
        public enum Kind: Sendable {
            case synthetic(pattern: String, colour: SIMD4<Float>)
            case texture   // frames vêm do FrameStore (ficheiros, câmaras, ecrã)
        }
        public var kind: Kind
        public var fit: String
    }

    public var rev: Int
    public var rasterWidth: Int
    public var rasterHeight: Int
    public var fps: Double
    public var programInput: InputId?
    public var previewInput: InputId?
    public var transition: Transition?
    public var ftb: Bool
    public var overlays: [Layer]            // só os ligados, por ordem de slot
    public var multiviewTiles: [Layer]
    public var multiviewSize: (Int, Int)
    public var inputs: [InputId: InputSpec]

    public init(state: EngineState) {
        rev = state.rev
        rasterWidth = state.project.raster.width
        rasterHeight = state.project.raster.height
        fps = state.project.raster.fps
        programInput = state.program.inputId
        previewInput = state.preview.inputId
        ftb = state.program.ftb
        if let t = state.program.transition {
            transition = Transition(kind: t.kind, durationFrames: t.durationFrames, auto: t.auto,
                                    manualProgress: t.progress,
                                    wipeDirection: t.wipe?.direction ?? "left",
                                    wipeSoftness: t.wipe?.softness ?? 0.05,
                                    colour: RenderPlan.parseColour(t.colour) ?? SIMD4(0, 0, 0, 1),
                                    toInput: state.preview.inputId)
        } else {
            transition = nil
        }
        overlays = state.overlays.compactMap { o in
            guard o.on, let id = o.inputId, state.inputs[id] != nil else { return nil }
            return Layer(source: .input(id), rect: o.rect, crop: o.crop, opacity: o.opacity)
        }
        multiviewTiles = state.multiview.tiles.map { tile in
            switch tile.source {
            case "program": return Layer(source: .bus(.program), rect: tile.rect)
            case "preview": return Layer(source: .bus(.preview), rect: tile.rect)
            default: return Layer(source: .input(tile.source), rect: tile.rect)
            }
        }
        multiviewSize = (state.multiview.size.width, state.multiview.size.height)
        var specs: [InputId: InputSpec] = [:]
        for (id, input) in state.inputs {
            switch input.kind {
            case .synthetic:
                let pattern = input.config["pattern"]?.stringValue ?? "colour"
                let colour = RenderPlan.parseColour(input.config["colour"]?.stringValue) ?? SIMD4(0.1, 0.3, 0.7, 1)
                specs[id] = InputSpec(kind: .synthetic(pattern: pattern, colour: colour), fit: input.fit)
            default:
                specs[id] = InputSpec(kind: .texture, fit: input.fit)
            }
        }
        inputs = specs
    }

    /// "#rrggbb" ou "#rrggbbaa" → RGBA 0..1
    public static func parseColour(_ s: String?) -> SIMD4<Float>? {
        guard var hex = s?.trimmingCharacters(in: .whitespaces), hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.count == 6 || hex.count == 8, let v = UInt32(hex, radix: 16) else { return nil }
        if hex.count == 6 {
            return SIMD4(Float((v >> 16) & 0xff) / 255, Float((v >> 8) & 0xff) / 255, Float(v & 0xff) / 255, 1)
        }
        return SIMD4(Float((v >> 24) & 0xff) / 255, Float((v >> 16) & 0xff) / 255, Float((v >> 8) & 0xff) / 255, Float(v & 0xff) / 255)
    }
}

/// Frame mais recente de uma fonte com textura (ficheiro, câmara, ecrã, NDI…).
public struct SourceFrame: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    public let hostTimeNanos: UInt64
    public let fullRange: Bool
    public init(buffer: CVPixelBuffer, hostTimeNanos: UInt64, fullRange: Bool = false) {
        self.buffer = buffer; self.hostTimeNanos = hostTimeNanos; self.fullRange = fullRange
    }
}

/// Caixa de correio por fonte: o produtor substitui, a thread de vídeo lê o mais recente.
public final class FrameStore: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var frames: [InputId: SourceFrame] = [:]

    public init() {}

    public func push(_ frame: SourceFrame, for id: InputId) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        frames[id] = frame
    }

    public func latest(_ id: InputId) -> SourceFrame? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return frames[id]
    }

    public func remove(_ id: InputId) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        frames[id] = nil
    }
}
