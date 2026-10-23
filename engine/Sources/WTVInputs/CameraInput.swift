import AVFoundation
import Foundation
import WTVProtocol
import WTVVideo

/// Câmara USB/UVC/Continuity via AVFoundation. Pede 420v com IOSurface (zero-copy para o Metal).
/// Áudio embebido da câmara chega no passo seguinte (AVCaptureAudioDataOutput + conversão para 48 kHz).
public final class CameraInput: NSObject, InputSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let id: InputId
    private let ctx: InputContext
    private let uniqueId: String
    private let formatIndex: Int?
    private let session = AVCaptureSession()
    private let queue: DispatchQueue
    private var device: AVCaptureDevice?
    private var frameCount = 0
    private var watchdog: DispatchSourceTimer?
    private var lastFrameNanos: UInt64 = 0

    public init(id: InputId, ctx: InputContext, config: JSONValue) throws {
        guard let uid = config["uniqueId"]?.stringValue, !uid.isEmpty else { throw InputError.failed("uniqueId em falta") }
        self.id = id
        self.ctx = ctx
        uniqueId = uid
        formatIndex = config["formatIndex"]?.intValue
        queue = DispatchQueue(label: "wtv.camera.\(id)", qos: .userInteractive)
        super.init()
    }

    public func start() {
        ctx.report(id, .starting, nil, nil)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [self] ok in
                if ok { configure() } else { ctx.report(id, .error, nil, "PERMISSION_DENIED") }
            }
        default: ctx.report(id, .error, nil, "PERMISSION_DENIED")
        }
    }

    private func configure() {
        queue.async { [self] in
            guard let dev = AVCaptureDevice(uniqueID: uniqueId) else {
                ctx.report(id, .noSignal, nil, "DEVICE_UNAVAILABLE"); return
            }
            device = dev
            do {
                session.beginConfiguration()
                let input = try AVCaptureDeviceInput(device: dev)
                guard session.canAddInput(input) else { throw InputError.failed("não é possível adicionar a câmara") }
                session.addInput(input)
                if let idx = formatIndex, dev.formats.indices.contains(idx) {
                    try dev.lockForConfiguration()
                    dev.activeFormat = dev.formats[idx]
                    dev.unlockForConfiguration()
                }
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                output.setSampleBufferDelegate(self, queue: queue)
                guard session.canAddOutput(output) else { throw InputError.failed("não é possível adicionar a saída de vídeo") }
                session.addOutput(output)
                session.commitConfiguration()
                session.startRunning()
                let dims = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
                let fps = dev.activeVideoMinFrameDuration.seconds > 0 ? 1 / dev.activeVideoMinFrameDuration.seconds : 0
                ctx.report(id, .starting, VideoFormat(width: Int(dims.width), height: Int(dims.height), fps: fps, pixelFormat: "nv12"), nil)
                startWatchdog()
            } catch {
                session.commitConfiguration()
                ctx.report(id, .error, nil, "CAMERA_OPEN: \(error)")
            }
        }
    }

    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if HostClock.nowNanos() - self.lastFrameNanos > 2_000_000_000 { self.ctx.report(self.id, .noSignal, nil, "NO_FRAMES") }
        }
        t.resume()
        watchdog = t
    }

    public func stop() {
        watchdog?.cancel()
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            ctx.frames.remove(id)
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = HostClock.nowNanos()
        lastFrameNanos = now
        ctx.push(pb, hostTimeNanos: now)
        frameCount += 1
        if frameCount == 1 { ctx.report(id, .live, nil, nil) }
    }
}

/// Enumeração de câmaras e ecrãs para `state.devices`.
public enum DeviceDiscovery {
    public static func cameras() -> [VideoDevice] {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        return session.devices.map { d in
            let kind: String
            switch d.deviceType {
            case .builtInWideAngleCamera: kind = "builtin"
            case .continuityCamera, .deskViewCamera: kind = "continuity"
            default: kind = d.transportType == 0x76697274 ? "virtual" : "usb" // "virt"
            }
            let formats = d.formats.map { f -> VideoDeviceFormat in
                let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                let fps = f.videoSupportedFrameRateRanges.map { Double($0.maxFrameRate) }
                let fourcc = CMFormatDescriptionGetMediaSubType(f.formatDescription)
                return VideoDeviceFormat(width: Int(dims.width), height: Int(dims.height), fps: fps, pixelFormat: fourccString(fourcc))
            }
            return VideoDevice(uniqueId: d.uniqueID, name: d.localizedName, kind: kind, formats: formats)
        }
    }

    public static func fourccString(_ v: FourCharCode) -> String {
        let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? String(v)
    }
}
