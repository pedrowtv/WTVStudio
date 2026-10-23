import AppKit
import Foundation
import Logging
import Metal
import QuartzCore

/// Janela de projector (D16). Regras de segurança, aprendidas à custa de um Mac bloqueado:
/// - a apresentação corre numa thread própria (CVDisplayLink), nunca na thread de vídeo;
/// - a janela responde a Esc e Cmd+W (fecha e avisa o motor) e tem sempre botão de fechar em modo janela;
/// - em ecrã inteiro fica ao nível normal (não acima da barra de menus) e pode ser coberta pela interface.
public final class Projector: @unchecked Sendable {
    public let displayId: String
    public let fullscreen: Bool
    public var onClose: (@Sendable () -> Void)?

    private var window: ProjectorWindow?
    private let layer = CAMetalLayer()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var lock = os_unfair_lock()
    private var latest: MTLTexture?
    private var presented: MTLTexture?
    private var displayLink: CVDisplayLink?
    private var ready = false
    private let log = Logger(label: "wtv.projector")

    public init(device: MTLDevice, displayId: String, fullscreen: Bool, size: (Int, Int)) {
        self.device = device
        self.displayId = displayId
        self.fullscreen = fullscreen
        queue = device.makeCommandQueue()!
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.isOpaque = true
        layer.displaySyncEnabled = true
        layer.allowsNextDrawableTimeout = true
        layer.drawableSize = CGSize(width: size.0, height: size.1)
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = CGColor.black
        // RunLoop.main.perform em vez de DispatchQueue.main: com o ciclo do AppKit a correr dentro do
        // executor do MainActor, os blocos da fila principal do GCD não são drenados; o run loop é.
        RunLoop.main.perform { [self] in self.open() }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func open() {
        log.info("a abrir janela (main thread: \(Thread.isMainThread), ecrãs: \(NSScreen.screens.count))")
        let screen = NSScreen.screens.first { s in
            let num = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return String(num) == displayId
        } ?? NSScreen.main ?? NSScreen.screens[0]
        let rect = fullscreen ? screen.frame : NSRect(x: screen.frame.midX - 480, y: screen.frame.midY - 270, width: 960, height: 540)
        let style: NSWindow.StyleMask = fullscreen ? [.borderless] : [.titled, .resizable, .closable, .miniaturizable]
        let w = ProjectorWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false, screen: screen)
        w.title = "WTV Studio — Projector (Esc fecha)"
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.onEscape = { [weak self] in self?.requestClose() }
        if fullscreen {
            w.level = .normal
            w.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary]
            w.hidesOnDeactivate = false
        }
        let view = ProjectorView(frame: NSRect(origin: .zero, size: rect.size))
        // Vista com camada própria (layer-backed) e a CAMetalLayer como subcamada: é o padrão fiável no AppKit.
        view.wantsLayer = true
        view.layer?.backgroundColor = CGColor.black
        layer.frame = view.bounds
        layer.contentsScale = screen.backingScaleFactor
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        w.contentView = view
        w.makeFirstResponder(view)
        w.orderFrontRegardless()
        window = w
        log.info("janela criada nº \(w.windowNumber) visível \(w.isVisible) frame \(NSStringFromRect(w.frame))")
        startDisplayLink()
        os_unfair_lock_lock(&lock); ready = true; os_unfair_lock_unlock(&lock)
    }

    private func requestClose() {
        onClose?()
        close()
    }

    public func close() {
        os_unfair_lock_lock(&lock); ready = false; os_unfair_lock_unlock(&lock)
        if let displayLink { CVDisplayLinkStop(displayLink) }
        displayLink = nil
        RunLoop.main.perform { [self] in
            self.window?.orderOut(nil)
            self.window?.close()
            self.window = nil
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Chamado pela thread de vídeo: só guarda a referência à textura do bus (sem bloquear).
    public func submit(_ texture: MTLTexture) {
        os_unfair_lock_lock(&lock); latest = texture; os_unfair_lock_unlock(&lock)
    }

    // MARK: - Apresentação na thread do display link

    private func startDisplayLink() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
            self?.present()
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(link)
        displayLink = link
    }

    private var dbgCalls = 0
    private func present() {
        os_unfair_lock_lock(&lock)
        let ok = ready
        let tex = latest
        let same = tex === presented
        os_unfair_lock_unlock(&lock)
        dbgCalls += 1
        if dbgCalls == 1 || dbgCalls == 120 { log.info("present #\(dbgCalls): ready \(ok) textura \(tex != nil) igual \(same) drawableSize \(layer.drawableSize)") }
        guard ok, let tex, !same else { return }
        if layer.drawableSize.width != CGFloat(tex.width) || layer.drawableSize.height != CGFloat(tex.height) {
            layer.drawableSize = CGSize(width: tex.width, height: tex.height)
        }
        guard let drawable = layer.nextDrawable() else { if dbgCalls < 5 { log.warning("nextDrawable devolveu nil") }; return }
        guard let cmd = queue.makeCommandBuffer() else { return }
        if ProcessInfo.processInfo.environment["WTV_PROJECTOR_TEST"] != nil {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 1, blue: 0, alpha: 1)
            cmd.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            cmd.present(drawable)
            cmd.commit()
            return
        }
        guard let blit = cmd.makeBlitCommandEncoder() else { return }
        let w = min(tex.width, drawable.texture.width), h = min(tex.height, drawable.texture.height)
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: drawable.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        os_unfair_lock_lock(&lock); presented = tex; os_unfair_lock_unlock(&lock)
    }
}

/// Janela que aceita teclado mesmo sem bordas e fecha com Esc / Cmd+W.
final class ProjectorWindow: NSWindow {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w") {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func close() {
        super.close()
    }
    override func performClose(_ sender: Any?) { onEscape?() }
}

final class ProjectorView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
}
