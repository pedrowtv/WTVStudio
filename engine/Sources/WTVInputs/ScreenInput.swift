import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit
import WTVProtocol
import WTVVideo

/// Captura de ecrã ou janela com ScreenCaptureKit (BGRA com IOSurface).
public final class ScreenInput: NSObject, InputSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public let id: InputId
    private let ctx: InputContext
    private let displayId: String?
    private let windowId: Int?
    private let showCursor: Bool
    private let fps: Double
    private var stream: SCStream?
    private let queue: DispatchQueue
    private var frameCount = 0

    public init(id: InputId, ctx: InputContext, config: JSONValue, fps: Double) {
        self.id = id
        self.ctx = ctx
        displayId = config["displayId"]?.stringValue
        windowId = config["windowId"]?.intValue
        showCursor = config["showCursor"]?.boolValue ?? true
        self.fps = fps
        queue = DispatchQueue(label: "wtv.screen.\(id)", qos: .userInteractive)
        super.init()
    }

    public func start() {
        ctx.report(id, .starting, nil, nil)
        Task { [self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let filter: SCContentFilter
                var width = 0, height = 0
                if let windowId, let win = content.windows.first(where: { Int($0.windowID) == windowId }) {
                    filter = SCContentFilter(desktopIndependentWindow: win)
                    width = Int(win.frame.width); height = Int(win.frame.height)
                } else {
                    let display: SCDisplay
                    if let displayId, let d = content.displays.first(where: { String($0.displayID) == displayId }) { display = d }
                    else if let d = content.displays.first { display = d }
                    else { throw InputError.notFound("ecrã") }
                    filter = SCContentFilter(display: display, excludingWindows: [])
                    width = display.width; height = display.height
                }
                let cfg = SCStreamConfiguration()
                cfg.width = width * 2  // Retina: captura à resolução nativa
                cfg.height = height * 2
                cfg.pixelFormat = kCVPixelFormatType_32BGRA
                cfg.showsCursor = showCursor
                cfg.queueDepth = 5
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
                cfg.capturesAudio = false
                let s = SCStream(filter: filter, configuration: cfg, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await s.startCapture()
                stream = s
                ctx.report(id, .starting, VideoFormat(width: cfg.width, height: cfg.height, fps: fps, pixelFormat: "bgra"), nil)
            } catch {
                let code = (error as NSError).domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && (error as NSError).code == -3801 ? "PERMISSION_DENIED" : "SCREEN_OPEN: \(error.localizedDescription)"
                ctx.report(id, .error, nil, code)
            }
        }
    }

    public func stop() {
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
        ctx.frames.remove(id)
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Frames "idle" (sem alteração) vêm com status != complete; o último frame continua válido no FrameStore.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let status = attachments.first?[.status] as? Int, status != SCFrameStatus.complete.rawValue {
            return
        }
        ctx.push(pb, hostTimeNanos: HostClock.nowNanos(), fullRange: true)
        frameCount += 1
        if frameCount == 1 { ctx.report(id, .live, nil, nil) }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        ctx.report(id, .noSignal, nil, "SCREEN_STOPPED: \(error.localizedDescription)")
    }

    public static func displays() -> [Display] {
        NSScreen.screens.map { s in
            let num = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let mode = CGDisplayCopyDisplayMode(num)
            return Display(id: String(num), name: s.localizedName, width: Int(s.frame.width * s.backingScaleFactor), height: Int(s.frame.height * s.backingScaleFactor),
                           refreshHz: mode?.refreshRate ?? 0, isMain: s == NSScreen.main)
        }
    }
}
