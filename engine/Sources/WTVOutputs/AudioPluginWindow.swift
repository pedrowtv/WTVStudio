import AppKit
import AudioToolbox
import CoreAudioKit
import Foundation
import WTVAudio

/// Janela com a vista de parâmetros de um Audio Unit (AUGenericView, ou a vista própria do plugin quando existe).
/// Criação na main thread via run loop (o ciclo do AppKit corre no executor do MainActor; ver Projector).
public final class AudioPluginWindow {
    nonisolated(unsafe) private static var windows: [String: NSWindow] = [:]

    public static func open(plugin: HostedAudioUnit, title: String) {
        RunLoop.main.perform {
            if let w = windows[plugin.pluginId] { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
            guard let unit = plugin.unit else { return }
            let view: NSView
            if let custom = loadCustomView(unit) { view = custom } else { view = AUGenericView(audioUnit: unit) }
            var size = view.fittingSize
            if size.width < 320 || size.height < 200 { size = NSSize(width: max(size.width, 560), height: max(size.height, 420)) }
            view.frame = NSRect(origin: .zero, size: size)
            view.autoresizingMask = [.width, .height]
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = title
            w.isReleasedWhenClosed = false
            w.contentView = view
            w.center()
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            windows[plugin.pluginId] = w
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    public static func close(pluginId: String) {
        RunLoop.main.perform {
            windows[pluginId]?.close()
            windows[pluginId] = nil
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Vista Cocoa própria do plugin (kAudioUnitProperty_CocoaUI), se o AU a fornecer.
    private static func loadCustomView(_ unit: AudioUnit) -> NSView? {
        var size: UInt32 = 0
        var writable: DarwinBoolean = false
        guard AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &size, &writable) == noErr, size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioUnitCocoaViewInfo>.size
        guard count > 0 else { return nil }
        let info = UnsafeMutablePointer<AudioUnitCocoaViewInfo>.allocate(capacity: count)
        defer { info.deallocate() }
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, info, &size) == noErr else { return nil }
        let bundleURL = info.pointee.mCocoaAUViewBundleLocation.takeUnretainedValue() as URL
        let className = info.pointee.mCocoaAUViewClass.takeUnretainedValue() as String
        guard let bundle = Bundle(url: bundleURL), let cls = bundle.classNamed(className) as? NSObject.Type else { return nil }
        let factory = cls.init()
        guard factory.responds(to: NSSelectorFromString("uiViewForAudioUnit:withSize:")) else { return nil }
        let sel = NSSelectorFromString("uiViewForAudioUnit:withSize:")
        typealias Fn = @convention(c) (AnyObject, Selector, AudioUnit, NSSize) -> NSView?
        let imp = factory.method(for: sel)
        let fn = unsafeBitCast(imp, to: Fn.self)
        return fn(factory, sel, unit, NSSize(width: 480, height: 360))
    }
}
