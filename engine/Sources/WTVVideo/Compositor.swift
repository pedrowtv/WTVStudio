import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import WTVProtocol

/// Uniforms do shader de camada. Tem de coincidir byte a byte com `LayerUniforms` em ShaderSources.
struct LayerUniforms {
    var rect: SIMD4<Float>
    var crop: SIMD4<Float>
    var colour: SIMD4<Float>
    var opacity: Float
    var kind: Int32
    var wipeMode: Int32
    var wipeProgress: Float
    var wipeSoftness: Float
    var time: Float
    var flashOn: Int32
    var fullRange: Int32
}

/// Resultado de um tick: buffers prontos para codificadores, NDI, projector.
public struct RenderedFrame: @unchecked Sendable {
    public let tick: Int64
    public let hostTimeNanos: UInt64
    public let program: CVPixelBuffer        // BGRA
    public let preview: CVPixelBuffer        // BGRA
    public let multiview: CVPixelBuffer?     // BGRA (nil nos ticks em que não é renderizado)
    public let multiviewNV12: CVPixelBuffer? // NV12 para o codificador de preview
    public let programNV12: CVPixelBuffer?   // NV12 para o codificador de Program (só quando há saídas)
}

/// Compositor Metal: um render pass por bus (D10). Só é chamado pela thread de vídeo.
public final class Compositor: @unchecked Sendable {
    public let metal: MetalContext
    private var rasterWidth = 0
    private var rasterHeight = 0
    private var programPool: CVPixelBufferPool?
    private var previewPool: CVPixelBufferPool?
    private var multiviewPool: CVPixelBufferPool?
    private var multiviewNV12Pool: CVPixelBufferPool?
    private var programNV12Pool: CVPixelBufferPool?
    private var multiviewSize = (0, 0)
    private var textureCache: [ObjectIdentifier: MTLTexture] = [:] // por IOSurface dos buffers do pool
    public let frames: FrameStore
    private var startNanos: UInt64 = 0

    public init(metal: MetalContext, frames: FrameStore) {
        self.metal = metal
        self.frames = frames
    }

    private func ensurePools(plan: RenderPlan) throws {
        if plan.rasterWidth != rasterWidth || plan.rasterHeight != rasterHeight {
            rasterWidth = plan.rasterWidth
            rasterHeight = plan.rasterHeight
            programPool = try MetalContext.makePool(width: rasterWidth, height: rasterHeight, format: kCVPixelFormatType_32BGRA, count: 3)
            previewPool = try MetalContext.makePool(width: rasterWidth, height: rasterHeight, format: kCVPixelFormatType_32BGRA, count: 2)
            programNV12Pool = try MetalContext.makePool(width: rasterWidth, height: rasterHeight, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, count: 4)
            textureCache.removeAll()
        }
        if plan.multiviewSize.0 != multiviewSize.0 || plan.multiviewSize.1 != multiviewSize.1 {
            multiviewSize = plan.multiviewSize
            multiviewPool = try MetalContext.makePool(width: multiviewSize.0, height: multiviewSize.1, format: kCVPixelFormatType_32BGRA, count: 2)
            multiviewNV12Pool = try MetalContext.makePool(width: multiviewSize.0, height: multiviewSize.1, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, count: 4)
        }
    }

    private func bgraTarget(_ buffer: CVPixelBuffer) -> MTLTexture? {
        metal.bgraTexture(for: buffer, usage: [.renderTarget, .shaderRead])
    }

    /// Renderiza Program, Preview e (opcionalmente) Multiview para o tick dado.
    public func render(plan: RenderPlan, tick: Int64, hostTimeNanos: UInt64, transitionProgress: Double, renderMultiview: Bool,
                       encodeProgram: Bool = false,
                       beforeCommit: ((MTLCommandBuffer, MTLTexture, MTLTexture?) -> Void)? = nil) throws -> RenderedFrame {
        try ensurePools(plan: plan)
        if startNanos == 0 { startNanos = hostTimeNanos }
        let time = Float(Double(hostTimeNanos &- startNanos) / 1e9)
        guard let programPool, let previewPool else { throw VideoError.metal("pools") }

        let programBuf = try MetalContext.makeBuffer(from: programPool)
        let previewBuf = try MetalContext.makeBuffer(from: previewPool)
        guard let programTex = bgraTarget(programBuf), let previewTex = bgraTarget(previewBuf) else { throw VideoError.metal("texturas de bus") }
        guard let cmd = metal.queue.makeCommandBuffer() else { throw VideoError.metal("command buffer") }

        // Preview: a fonte de preview com os overlays tal como ficarão (D10)
        try renderBus(cmd: cmd, target: previewTex, plan: plan, time: time, tick: tick) { enc in
            if let id = plan.previewInput { self.drawInput(enc, id: id, plan: plan, rect: .full, opacity: 1, time: time, tick: tick) }
            for o in plan.overlays { self.drawLayer(enc, layer: o, plan: plan, time: time, tick: tick, buses: nil) }
        }

        // Program: base A, depois B com progresso da transição, depois overlays, depois FTB
        try renderBus(cmd: cmd, target: programTex, plan: plan, time: time, tick: tick) { enc in
            if let id = plan.programInput { self.drawInput(enc, id: id, plan: plan, rect: .full, opacity: 1, time: time, tick: tick) }
            if let t = plan.transition, let to = t.toInput, transitionProgress > 0 {
                let p = Float(min(1, transitionProgress))
                switch t.kind {
                case "wipe":
                    self.drawInput(enc, id: to, plan: plan, rect: .full, opacity: 1, time: time, tick: tick,
                                   wipe: (Compositor.wipeMode(t.wipeDirection), p, Float(t.wipeSoftness)))
                case "dip":
                    // metade: fundir para a cor; metade: da cor para B
                    if p < 0.5 {
                        self.drawSolid(enc, colour: t.colour, rect: .full, opacity: p * 2)
                    } else {
                        self.drawInput(enc, id: to, plan: plan, rect: .full, opacity: 1, time: time, tick: tick)
                        self.drawSolid(enc, colour: t.colour, rect: .full, opacity: (1 - p) * 2)
                    }
                default: // fade
                    self.drawInput(enc, id: to, plan: plan, rect: .full, opacity: p, time: time, tick: tick)
                }
            }
            for o in plan.overlays { self.drawLayer(enc, layer: o, plan: plan, time: time, tick: tick, buses: nil) }
            if plan.ftb { self.drawSolid(enc, colour: SIMD4(0, 0, 0, 1), rect: .full, opacity: 1) }
        }

        var multiviewBuf: CVPixelBuffer?
        var nv12Buf: CVPixelBuffer?
        var programNV12: CVPixelBuffer?
        var mvTexture: MTLTexture?
        if encodeProgram, let programNV12Pool {
            let nv = try MetalContext.makeBuffer(from: programNV12Pool)
            try convertToNV12(cmd: cmd, source: programTex, destination: nv)
            programNV12 = nv
        }
        if renderMultiview, let multiviewPool, let multiviewNV12Pool {
            let mv = try MetalContext.makeBuffer(from: multiviewPool)
            guard let mvTex = bgraTarget(mv) else { throw VideoError.metal("textura multiview") }
            mvTexture = mvTex
            try renderBus(cmd: cmd, target: mvTex, plan: plan, time: time, tick: tick) { enc in
                for tile in plan.multiviewTiles {
                    self.drawLayer(enc, layer: tile, plan: plan, time: time, tick: tick, buses: (programTex, previewTex))
                }
            }
            let nv12 = try MetalContext.makeBuffer(from: multiviewNV12Pool)
            try convertToNV12(cmd: cmd, source: mvTex, destination: nv12)
            multiviewBuf = mv
            nv12Buf = nv12
        }

        beforeCommit?(cmd, programTex, mvTexture)
        cmd.commit()
        cmd.waitUntilCompleted()
        if let err = cmd.error { throw VideoError.metal("GPU: \(err)") }
        return RenderedFrame(tick: tick, hostTimeNanos: hostTimeNanos, program: programBuf, preview: previewBuf, multiview: multiviewBuf, multiviewNV12: nv12Buf, programNV12: programNV12)
    }

    private func renderBus(cmd: MTLCommandBuffer, target: MTLTexture, plan: RenderPlan, time: Float, tick: Int64, body: (MTLRenderCommandEncoder) -> Void) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { throw VideoError.metal("render encoder") }
        enc.setRenderPipelineState(metal.layerPipeline)
        body(enc)
        enc.endEncoding()
    }

    private func drawLayer(_ enc: MTLRenderCommandEncoder, layer: RenderPlan.Layer, plan: RenderPlan, time: Float, tick: Int64, buses: (MTLTexture, MTLTexture)?) {
        switch layer.source {
        case .input(let id):
            drawInput(enc, id: id, plan: plan, rect: layer.rect, crop: layer.crop, opacity: Float(layer.opacity), time: time, tick: tick)
        case .bus(let bus):
            guard let buses else { return }
            let tex = bus == .program ? buses.0 : buses.1
            var u = Compositor.uniforms(rect: layer.rect, crop: layer.crop, opacity: Float(layer.opacity), kind: 0, time: time)
            enc.setFragmentTexture(tex, index: 0)
            draw(enc, &u)
        }
    }

    private func drawInput(_ enc: MTLRenderCommandEncoder, id: InputId, plan: RenderPlan, rect: Rect, crop: Rect = .full, opacity: Float, time: Float, tick: Int64,
                           wipe: (Int32, Float, Float)? = nil) {
        guard let spec = plan.inputs[id] else {
            drawSolid(enc, colour: SIMD4(0.15, 0.15, 0.15, 1), rect: rect, opacity: opacity)
            return
        }
        var u = Compositor.uniforms(rect: rect, crop: crop, opacity: opacity, kind: 6, time: time)
        if let wipe { u.wipeMode = wipe.0; u.wipeProgress = wipe.1; u.wipeSoftness = wipe.2 }
        switch spec.kind {
        case .synthetic(let pattern, let colour):
            u.colour = colour
            switch pattern {
            case "bars": u.kind = 3
            case "testPattern": u.kind = 4
            case "sync":
                u.kind = 5
                // flash de 1 frame no primeiro tick de cada segundo (o beep do áudio dispara no mesmo segundo)
                let second = Int(Double(tick) / plan.fps), prev = Int(Double(max(0, tick - 1)) / plan.fps)
                u.flashOn = (tick == 0 || second != prev) ? 1 : 0
            default: u.kind = 2
            }
            draw(enc, &u)
        case .texture:
            guard let frame = frames.latest(id) else {
                drawSolid(enc, colour: SIMD4(0.1, 0.1, 0.1, 1), rect: rect, opacity: opacity) // SEM SINAL
                return
            }
            let fmt = CVPixelBufferGetPixelFormatType(frame.buffer)
            u.fullRange = frame.fullRange ? 1 : 0
            u.crop = Compositor.fitCrop(spec.fit, src: (CVPixelBufferGetWidth(frame.buffer), CVPixelBufferGetHeight(frame.buffer)),
                                        dst: (Float(rect.w) * Float(rasterWidth), Float(rect.h) * Float(rasterHeight)), crop: crop)
            if fmt == kCVPixelFormatType_32BGRA {
                guard let tex = metal.bgraTexture(for: frame.buffer, usage: .shaderRead) else { return }
                u.kind = 0
                enc.setFragmentTexture(tex, index: 0)
            } else if fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
                guard let (y, c) = metal.nv12Textures(for: frame.buffer, usage: .shaderRead) else { return }
                u.kind = 1
                u.fullRange = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1 : 0
                enc.setFragmentTexture(y, index: 0)
                enc.setFragmentTexture(c, index: 1)
            } else {
                drawSolid(enc, colour: SIMD4(0.3, 0, 0.3, 1), rect: rect, opacity: opacity) // formato não suportado
                return
            }
            draw(enc, &u)
        }
    }

    private func drawSolid(_ enc: MTLRenderCommandEncoder, colour: SIMD4<Float>, rect: Rect, opacity: Float) {
        var u = Compositor.uniforms(rect: rect, crop: .full, opacity: opacity, kind: 2, time: 0)
        u.colour = colour
        draw(enc, &u)
    }

    private func draw(_ enc: MTLRenderCommandEncoder, _ u: inout LayerUniforms) {
        enc.setVertexBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func convertToNV12(cmd: MTLCommandBuffer, source: MTLTexture, destination: CVPixelBuffer) throws {
        guard let (y, c) = metal.nv12Textures(for: destination, usage: .shaderWrite) else { throw VideoError.metal("texturas NV12") }
        guard let enc = cmd.makeComputeCommandEncoder() else { throw VideoError.metal("compute encoder") }
        enc.setComputePipelineState(metal.nv12Pipeline)
        enc.setTexture(source, index: 0)
        enc.setTexture(y, index: 1)
        enc.setTexture(c, index: 2)
        let w = metal.nv12Pipeline.threadExecutionWidth
        let h = max(1, metal.nv12Pipeline.maxTotalThreadsPerThreadgroup / w)
        let grid = MTLSize(width: (source.width + 1) / 2, height: (source.height + 1) / 2, depth: 1)
        enc.dispatchThreads(grid, threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc.endEncoding()
    }

    // MARK: - Helpers

    static func uniforms(rect: Rect, crop: Rect, opacity: Float, kind: Int32, time: Float) -> LayerUniforms {
        LayerUniforms(rect: SIMD4(Float(rect.x), Float(rect.y), Float(rect.w), Float(rect.h)),
                      crop: SIMD4(Float(crop.x), Float(crop.y), Float(crop.w), Float(crop.h)),
                      colour: SIMD4(0, 0, 0, 1), opacity: opacity, kind: kind, wipeMode: 0, wipeProgress: 0, wipeSoftness: 0.05,
                      time: time, flashOn: 0, fullRange: 0)
    }

    static func wipeMode(_ direction: String) -> Int32 {
        switch direction {
        case "left": return 1
        case "right": return 2
        case "up": return 3
        case "down": return 4
        case "box": return 5
        case "circle": return 6
        case "diagonalUp": return 7
        case "diagonalDown": return 8
        default: return 1
        }
    }

    /// Modo "fit" (letterbox) por omissão; "fill" recorta; "stretch" ignora proporção.
    static func fitCrop(_ mode: String, src: (Int, Int), dst: (Float, Float), crop: Rect) -> SIMD4<Float> {
        let base = SIMD4(Float(crop.x), Float(crop.y), Float(crop.w), Float(crop.h))
        guard src.0 > 0, src.1 > 0, dst.0 > 0, dst.1 > 0, mode == "fill" else { return base }
        let srcAspect = Float(src.0) / Float(src.1)
        let dstAspect = dst.0 / dst.1
        if srcAspect > dstAspect {
            let w = dstAspect / srcAspect
            return SIMD4(base.x + (1 - w) / 2 * base.z, base.y, base.z * w, base.w)
        } else {
            let h = srcAspect / dstAspect
            return SIMD4(base.x, base.y + (1 - h) / 2 * base.w, base.z, base.w * h)
        }
    }

    // MARK: - Snapshot PNG (testes e /api/snapshot.png)

    public static func pngData(from buffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr, space: cs, bitmapInfo: info.rawValue),
              let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
