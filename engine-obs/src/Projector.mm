#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include "Projector.h"
#include <thread>

@interface WTVProjectorView : NSView
@property (nonatomic) obs_display_t *display;
@end
@implementation WTVProjectorView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)wantsUpdateLayer { return YES; }
- (void)keyDown:(NSEvent *)e {
    if (e.keyCode == 53 || ([e.charactersIgnoringModifiers isEqualToString:@"w"] && (e.modifierFlags & NSEventModifierFlagCommand))) [self.window close];
    else [super keyDown:e];
}
- (void)setFrameSize:(NSSize)s {
    [super setFrameSize:s];
    if (self.display) { CGFloat k = self.window.backingScaleFactor ?: 2; obs_display_resize(self.display, (uint32_t)(s.width * k), (uint32_t)(s.height * k)); }
}
@end

@interface WTVProjectorWindowDelegate : NSObject <NSWindowDelegate>
@property (nonatomic, copy) void (^onClose)(void);
@end
@implementation WTVProjectorWindowDelegate
- (void)windowWillClose:(NSNotification *)n { if (self.onClose) self.onClose(); }
@end

namespace {
NSWindow *g_window = nil;
WTVProjectorView *g_view = nil;
WTVProjectorWindowDelegate *g_delegate = nil;
obs_display_t *g_display = nullptr;
obs_source_t *g_source = nullptr; // nullptr = Program
std::function<void()> g_onClosed;

void draw(void *, uint32_t cx, uint32_t cy) {
    uint32_t tw, th;
    if (g_source) { tw = obs_source_get_width(g_source); th = obs_source_get_height(g_source); }
    else { obs_video_info ovi{}; obs_get_video_info(&ovi); tw = ovi.base_width; th = ovi.base_height; }
    if (!tw || !th) return;
    float scale = std::min((float)cx / tw, (float)cy / th);
    int w = (int)(tw * scale), h = (int)(th * scale), x = ((int)cx - w) / 2, y = ((int)cy - h) / 2;
    gs_projection_push(); gs_viewport_push();
    gs_set_viewport(x, y, w, h);
    gs_ortho(0.f, (float)tw, 0.f, (float)th, -100.f, 100.f);
    if (g_source) obs_source_video_render(g_source); else obs_render_main_texture();
    gs_viewport_pop(); gs_projection_pop();
}

void destroyOnMain() {
    if (g_display) { obs_display_destroy(g_display); g_display = nullptr; }
    if (g_source) { obs_source_dec_showing(g_source); g_source = nullptr; }
    g_view.display = nullptr;
    g_window = nil; g_view = nil; g_delegate = nil;
}

NSScreen *screenFor(const std::string &displayId) {
    for (NSScreen *s in NSScreen.screens) {
        NSNumber *n = s.deviceDescription[@"NSScreenNumber"];
        if (std::to_string(n.unsignedIntValue) == displayId) return s;
    }
    return NSScreen.mainScreen;
}
}

namespace Projector {
int runMainLoop(const std::function<void()> &engineBody) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];
        std::thread([engineBody] {
            engineBody();
            dispatch_async(dispatch_get_main_queue(), ^{ [NSApp stop:nil]; [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:YES]; });
        }).detach();
        [NSApp run];
    }
    return 0;
}

json displays() {
    json out = json::array();
    for (NSScreen *s in NSScreen.screens) {
        NSNumber *n = s.deviceDescription[@"NSScreenNumber"];
        NSRect f = s.frame; CGFloat k = s.backingScaleFactor;
        CGDirectDisplayID did = n.unsignedIntValue;
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(did);
        double hz = mode ? CGDisplayModeGetRefreshRate(mode) : 0; if (mode) CGDisplayModeRelease(mode);
        out.push_back({{"id", std::to_string(did)}, {"name", s.localizedName.UTF8String}, {"width", (int)(f.size.width * k)}, {"height", (int)(f.size.height * k)},
                       {"refreshHz", hz > 0 ? hz : 60.0}, {"isMain", s == NSScreen.screens.firstObject}});
    }
    return out;
}

bool isOpen() { return g_window != nil; }

void close() {
    dispatch_async(dispatch_get_main_queue(), ^{ if (g_window) { NSWindow *w = g_window; g_delegate.onClose = nil; destroyOnMain(); [w close]; } });
}

void open(const std::string &displayId, obs_source_t *source, bool fullscreen, std::function<void()> onClosed) {
    if (source) obs_source_inc_showing(source);
    g_onClosed = std::move(onClosed);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_window) { NSWindow *w = g_window; g_delegate.onClose = nil; destroyOnMain(); [w close]; }
        NSScreen *screen = screenFor(displayId);
        bool isMain = screen == NSScreen.screens.firstObject;
        bool full = fullscreen && !isMain; // nunca ecrã inteiro no ecrã principal
        NSRect frame = full ? screen.frame : NSMakeRect(screen.frame.origin.x + 80, screen.frame.origin.y + 80, 960, 540);
        NSWindowStyleMask style = full ? NSWindowStyleMaskBorderless : (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable);
        NSWindow *w = [[NSWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO screen:screen];
        w.title = @"WTV Studio — Projector";
        w.backgroundColor = NSColor.blackColor;
        w.releasedWhenClosed = NO;
        if (full) { w.level = NSStatusWindowLevel; w.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorCanJoinAllSpaces; }
        else w.contentAspectRatio = NSMakeSize(16, 9);
        WTVProjectorView *v = [[WTVProjectorView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
        v.wantsLayer = YES;
        v.layer.backgroundColor = NSColor.blackColor.CGColor;
        w.contentView = v;
        CGFloat k = w.backingScaleFactor ?: 2;
        gs_init_data init{};
        init.cx = (uint32_t)(v.bounds.size.width * k); init.cy = (uint32_t)(v.bounds.size.height * k);
        init.format = GS_BGRA; init.zsformat = GS_ZS_NONE; init.num_backbuffers = 2;
        init.window.view = v;
        obs_display_t *d = obs_display_create(&init, 0xFF000000);
        if (!d) { blog(LOG_WARNING, "projector: obs_display_create falhou"); return; }
        obs_display_add_draw_callback(d, draw, nullptr);
        v.display = d;
        g_display = d; g_source = source; g_window = w; g_view = v;
        g_delegate = [WTVProjectorWindowDelegate new];
        g_delegate.onClose = ^{ destroyOnMain(); if (g_onClosed) g_onClosed(); };
        w.delegate = g_delegate;
        [w makeKeyAndOrderFront:nil];
        [w makeFirstResponder:v];
        [NSApp activateIgnoringOtherApps:YES];
    });
}
}
