import CoreVideo
import Foundation
import WTVAudio
import WTVProtocol
import WTVVideo

/// Contexto partilhado por todas as fontes: onde entregar frames e áudio, e como reportar estado.
public final class InputContext: @unchecked Sendable {
    public let id: InputId
    public let frames: FrameStore
    public let mixer: AudioMixer?
    /// Reporta estado (live, noSignal, error) e, opcionalmente, formato e código.
    public let report: @Sendable (InputId, InputStatus, VideoFormat?, String?) -> Void
    /// Reporta transporte de media (posição, duração, estado).
    public let reportMedia: @Sendable (InputId, MediaTransport) -> Void

    public init(id: InputId, frames: FrameStore, mixer: AudioMixer?,
                report: @escaping @Sendable (InputId, InputStatus, VideoFormat?, String?) -> Void,
                reportMedia: @escaping @Sendable (InputId, MediaTransport) -> Void) {
        self.id = id; self.frames = frames; self.mixer = mixer; self.report = report; self.reportMedia = reportMedia
    }

    public func push(_ buffer: CVPixelBuffer, hostTimeNanos: UInt64, fullRange: Bool = false) {
        frames.push(SourceFrame(buffer: buffer, hostTimeNanos: hostTimeNanos, fullRange: fullRange), for: id)
    }
}

/// Uma fonte de vídeo (e opcionalmente áudio). Cada tipo corre nas suas próprias threads/filas.
public protocol InputSource: AnyObject, Sendable {
    var id: InputId { get }
    func start()
    func stop()
    /// Comandos específicos (media.play, title.setFields…). Por omissão ignora.
    func handle(command: String, params: JSONValue) throws
    /// Configuração alterada (input.update).
    func update(config: JSONValue)
}

public extension InputSource {
    func handle(command: String, params: JSONValue) throws {}
    func update(config: JSONValue) {}
}

public enum InputError: Error, CustomStringConvertible {
    case notFound(String)
    case unsupported(String)
    case permission(String)
    case failed(String)

    public var description: String {
        switch self {
        case .notFound(let s): return "não encontrado: \(s)"
        case .unsupported(let s): return "não suportado: \(s)"
        case .permission(let s): return "sem permissão: \(s)"
        case .failed(let s): return s
        }
    }
}

public enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb); return tb
    }()
    public static func nowNanos() -> UInt64 {
        mach_absolute_time() * UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}

/// Buffers BGRA com IOSurface para imagens e títulos (uma só alocação por imagem).
public enum PixelBuffers {
    public static func makeBGRA(width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var buffer: CVPixelBuffer?
        let st = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        return st == kCVReturnSuccess ? buffer : nil
    }
}
