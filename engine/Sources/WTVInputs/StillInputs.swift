import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import WTVProtocol
import WTVVideo

/// Imagem estática (PNG/JPEG/HEIC…) → BGRA pré-multiplicado com IOSurface, enviada uma vez.
public final class ImageInput: InputSource, @unchecked Sendable {
    public let id: InputId
    private let ctx: InputContext
    private var path: String?

    public init(id: InputId, ctx: InputContext, config: JSONValue) {
        self.id = id
        self.ctx = ctx
        path = config["path"]?.stringValue
    }

    public func start() { load() }
    public func stop() { ctx.frames.remove(id) }

    public func update(config: JSONValue) {
        if let p = config["path"]?.stringValue { path = p; load() }
    }

    /// PNG enviado por PUT /api/inputs/{id}/image
    public func setImageData(_ data: Data) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            ctx.report(id, .error, nil, "IMAGE_DECODE"); return
        }
        push(img)
    }

    private func load() {
        guard let path, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            ctx.report(id, .noSignal, nil, "IMAGE_OPEN"); return
        }
        push(img)
    }

    private func push(_ img: CGImage) {
        guard let buffer = StillRenderer.render(width: img.width, height: img.height, { c in
            c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }) else { ctx.report(id, .error, nil, "IMAGE_BUFFER"); return }
        ctx.push(buffer, hostTimeNanos: HostClock.nowNanos(), fullRange: true)
        ctx.report(id, .live, VideoFormat(width: img.width, height: img.height, fps: 0, pixelFormat: "bgra"), nil)
    }
}

/// Título/oráculo renderizado com CoreText. Modelos: "lowerThird" (nome + função) e "fullscreen" (título).
public final class TitleInput: InputSource, @unchecked Sendable {
    public let id: InputId
    private let ctx: InputContext
    private var template: String
    private var fields: [String: String]
    private let size = (1920, 1080)

    public init(id: InputId, ctx: InputContext, config: JSONValue) {
        self.id = id
        self.ctx = ctx
        template = config["template"]?.stringValue ?? "lowerThird"
        fields = config["fields"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
    }

    public func start() { render() }
    public func stop() { ctx.frames.remove(id) }

    public func update(config: JSONValue) {
        if let t = config["template"]?.stringValue { template = t }
        if let f = config["fields"]?.objectValue { for (k, v) in f { fields[k] = v.stringValue } }
        render()
    }

    public func handle(command: String, params: JSONValue) throws {
        guard command == "title.setFields", let f = params["fields"]?.objectValue else { return }
        for (k, v) in f { fields[k] = v.stringValue }
        render()
    }

    private func render() {
        let w = size.0, h = size.1
        let fields = self.fields
        let template = self.template
        guard let buffer = StillRenderer.render(width: w, height: h, { c in
            switch template {
            case "fullscreen":
                c.setFillColor(CGColor(red: 0.05, green: 0.07, blue: 0.12, alpha: 0.92))
                c.fill(CGRect(x: 0, y: 0, width: w, height: h))
                StillRenderer.text(fields["title"] ?? "", in: c, rect: CGRect(x: 120, y: h / 2 - 60, width: w - 240, height: 160), size: 96, weight: .bold, colour: .white, align: .center)
                StillRenderer.text(fields["subtitle"] ?? "", in: c, rect: CGRect(x: 120, y: h / 2 - 180, width: w - 240, height: 100), size: 48, weight: .regular, colour: CGColor(gray: 0.85, alpha: 1), align: .center)
            default: // lowerThird
                let barH = 150, margin = 96, bottom = 110
                let bar = CGRect(x: margin, y: bottom, width: w - margin * 2, height: barH)
                c.setFillColor(CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.72))
                c.fill(bar)
                c.setFillColor(CGColor(red: 0.90, green: 0.15, blue: 0.15, alpha: 1))
                c.fill(CGRect(x: margin, y: bottom, width: 14, height: barH))
                StillRenderer.text(fields["name"] ?? "", in: c, rect: CGRect(x: CGFloat(margin + 40), y: CGFloat(bottom + 70), width: bar.width - 80, height: 70), size: 54, weight: .bold, colour: .white, align: .left)
                StillRenderer.text(fields["role"] ?? "", in: c, rect: CGRect(x: CGFloat(margin + 40), y: CGFloat(bottom + 14), width: bar.width - 80, height: 54), size: 36, weight: .regular, colour: CGColor(gray: 0.9, alpha: 1), align: .left)
            }
        }) else { ctx.report(id, .error, nil, "TITLE_RENDER"); return }
        ctx.push(buffer, hostTimeNanos: HostClock.nowNanos(), fullRange: true)
        ctx.report(id, .live, VideoFormat(width: w, height: h, fps: 0, pixelFormat: "bgra"), nil)
    }
}

/// Desenha com CoreGraphics directamente na memória de um CVPixelBuffer BGRA pré-multiplicado.
enum StillRenderer {
    static func render(width: Int, height: Int, _ body: (CGContext) -> Void) -> CVPixelBuffer? {
        guard width > 0, height > 0, let buffer = PixelBuffers.makeBGRA(width: width, height: height) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * height)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let c = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: cs, bitmapInfo: info.rawValue) else { return nil }
        body(c)
        return buffer
    }

    static func text(_ s: String, in c: CGContext, rect: CGRect, size: CGFloat, weight: NSFont.Weight, colour: CGColor, align: NSTextAlignment) {
        guard !s.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: colour) ?? .white, .paragraphStyle: para]
        let str = NSAttributedString(string: s, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(str)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, c)
    }
}
