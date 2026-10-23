import CoreVideo
import Foundation
import IOSurface
import Metal

/// Dispositivo Metal, biblioteca compilada em execução, pipelines e pools de buffers.
public final class MetalContext: @unchecked Sendable {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let library: MTLLibrary
    public let layerPipeline: MTLRenderPipelineState
    public let nv12Pipeline: MTLComputePipelineState

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw VideoError.noMetalDevice }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw VideoError.metal("command queue") }
        self.queue = queue

        let options = MTLCompileOptions()
        options.fastMathEnabled = true
        library = try device.makeLibrary(source: ShaderSources.compositor, options: options)

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "layerVertex")
        desc.fragmentFunction = library.makeFunction(name: "layerFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        layerPipeline = try device.makeRenderPipelineState(descriptor: desc)

        guard let kernel = library.makeFunction(name: "bgraToNV12") else { throw VideoError.metal("bgraToNV12") }
        nv12Pipeline = try device.makeComputePipelineState(function: kernel)
    }

    // MARK: - Pools e texturas

    public static func makePool(width: Int, height: Int, format: OSType, count: Int = 3) throws -> CVPixelBufferPool {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: format,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let poolAttrs: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: count]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { throw VideoError.metal("CVPixelBufferPool \(status)") }
        return pool
    }

    public static func makeBuffer(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw VideoError.metal("CVPixelBufferPoolCreatePixelBuffer \(status)") }
        return buffer
    }

    /// Textura Metal sobre a IOSurface de um CVPixelBuffer (zero-copy, D8).
    public func texture(for buffer: CVPixelBuffer, plane: Int = 0, format: MTLPixelFormat, usage: MTLTextureUsage) -> MTLTexture? {
        guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return nil }
        let planar = CVPixelBufferIsPlanar(buffer)
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        desc.usage = usage
        desc.storageMode = .shared
        return device.makeTexture(descriptor: desc, iosurface: surface, plane: plane)
    }

    /// Texturas (Y, CbCr) de um buffer NV12.
    public func nv12Textures(for buffer: CVPixelBuffer, usage: MTLTextureUsage) -> (MTLTexture, MTLTexture)? {
        guard let y = texture(for: buffer, plane: 0, format: .r8Unorm, usage: usage),
              let c = texture(for: buffer, plane: 1, format: .rg8Unorm, usage: usage) else { return nil }
        return (y, c)
    }

    public func bgraTexture(for buffer: CVPixelBuffer, usage: MTLTextureUsage) -> MTLTexture? {
        texture(for: buffer, plane: 0, format: .bgra8Unorm, usage: usage)
    }
}

public enum VideoError: Error, CustomStringConvertible {
    case noMetalDevice
    case metal(String)
    case encoder(String, Int32)

    public var description: String {
        switch self {
        case .noMetalDevice: return "sem dispositivo Metal"
        case .metal(let s): return "Metal: \(s)"
        case .encoder(let s, let code): return "VideoToolbox \(s): \(code)"
        }
    }
}
