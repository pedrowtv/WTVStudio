#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudioKit/CoreAudioKit.h>
#include "AudioUnitHost.h"
#include <map>
#include <mutex>
#include <vector>

/// Fechar a janela só a esconde: destruir a vista do plugin ao fechar faz crash em editores JUCE/WebKit (Prisma EQ Pro).
@interface WTVAUWindowDelegate : NSObject <NSWindowDelegate>
@end
@implementation WTVAUWindowDelegate
- (BOOL)windowShouldClose:(NSWindow *)w { [w orderOut:nil]; return NO; }
@end

namespace {
WTVAUWindowDelegate *g_auDelegate = nil;
std::string fourcc(UInt32 v) { char s[5] = {(char)(v >> 24), (char)(v >> 16), (char)(v >> 8), (char)v, 0}; return s; }
UInt32 fromFourcc(const std::string &s) { return s.size() == 4 ? ((UInt32)(uint8_t)s[0] << 24) | ((UInt32)(uint8_t)s[1] << 16) | ((UInt32)(uint8_t)s[2] << 8) | (uint8_t)s[3] : 0; }

struct Host {
    obs_source_t *ctx;
    AudioUnit unit = nullptr;
    std::string component;
    int chans = 2, rate = 48000;
    std::vector<std::vector<float>> input;   // planos pendentes para o callback de entrada
    std::vector<std::vector<float>> output;
    AudioTimeStamp ts{};
    std::mutex m;
    bool ok = false;
};

OSStatus inputCb(void *ref, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32 frames, AudioBufferList *io) {
    auto *h = static_cast<Host *>(ref);
    for (UInt32 b = 0; b < io->mNumberBuffers; b++) {
        float *dst = static_cast<float *>(io->mBuffers[b].mData);
        if (!dst) continue;
        if (b < h->input.size() && h->input[b].size() >= frames) memcpy(dst, h->input[b].data(), frames * sizeof(float));
        else memset(dst, 0, frames * sizeof(float));
    }
    return noErr;
}

void teardown(Host *h) {
    if (h->unit) { AudioUnitUninitialize(h->unit); AudioComponentInstanceDispose(h->unit); h->unit = nullptr; }
    h->ok = false;
}

bool setup(Host *h) {
    teardown(h);
    std::string c = h->component;
    if (c.rfind("au:", 0) == 0) c = c.substr(3);
    if (c.size() != 14 || c[4] != ':' || c[9] != ':') return false;
    AudioComponentDescription d{fromFourcc(c.substr(0, 4)), fromFourcc(c.substr(5, 4)), fromFourcc(c.substr(10, 4)), 0, 0};
    AudioComponent comp = AudioComponentFindNext(nullptr, &d);
    if (!comp) { blog(LOG_WARNING, "AU %s não encontrado", h->component.c_str()); return false; }
    if (AudioComponentInstanceNew(comp, &h->unit) != noErr || !h->unit) return false;
    obs_audio_info oai{}; obs_get_audio_info(&oai);
    h->rate = (int)oai.samples_per_sec; h->chans = (int)get_audio_channels(oai.speakers);
    AudioStreamBasicDescription fmt{};
    fmt.mSampleRate = h->rate; fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    fmt.mBytesPerPacket = 4; fmt.mFramesPerPacket = 1; fmt.mBytesPerFrame = 4; fmt.mChannelsPerFrame = h->chans; fmt.mBitsPerChannel = 32;
    AudioUnitSetProperty(h->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof fmt);
    AudioUnitSetProperty(h->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &fmt, sizeof fmt);
    UInt32 maxF = 4096;
    AudioUnitSetProperty(h->unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxF, sizeof maxF);
    AURenderCallbackStruct cb{inputCb, h};
    AudioUnitSetProperty(h->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
    if (AudioUnitInitialize(h->unit) != noErr) { blog(LOG_WARNING, "AU %s: AudioUnitInitialize falhou", h->component.c_str()); AudioComponentInstanceDispose(h->unit); h->unit = nullptr; return false; }
    h->input.assign(h->chans, {}); h->output.assign(h->chans, {});
    h->ts = AudioTimeStamp{}; h->ts.mFlags = kAudioTimeStampSampleTimeValid;
    h->ok = true;
    blog(LOG_INFO, "AU %s alojado (%d canais, %d Hz)", h->component.c_str(), h->chans, h->rate);
    return true;
}

void update(void *d, obs_data_t *s) {
    auto *h = static_cast<Host *>(d);
    std::string c = obs_data_get_string(s, "component");
    std::lock_guard l(h->m);
    if (c != h->component || !h->ok) { h->component = c; setup(h); }
}
void *create(obs_data_t *s, obs_source_t *ctx) { auto *h = new Host{ctx}; update(h, s); return h; }
void destroy(void *d) { auto *h = static_cast<Host *>(d); AudioUnitHost::closeWindow(h->ctx); { std::lock_guard l(h->m); teardown(h); } delete h; }

obs_audio_data *filterAudio(void *d, obs_audio_data *audio) {
    auto *h = static_cast<Host *>(d);
    std::lock_guard l(h->m);
    if (!h->ok) return audio;
    UInt32 n = audio->frames;
    for (int c = 0; c < h->chans; c++) {
        const float *x = reinterpret_cast<const float *>(audio->data[c]);
        h->input[c].assign(n, 0.f);
        if (x) memcpy(h->input[c].data(), x, n * sizeof(float));
        h->output[c].assign(n, 0.f);
    }
    std::vector<uint8_t> ablMem(sizeof(AudioBufferList) + sizeof(AudioBuffer) * h->chans);
    auto *abl = reinterpret_cast<AudioBufferList *>(ablMem.data());
    abl->mNumberBuffers = h->chans;
    for (int c = 0; c < h->chans; c++) { abl->mBuffers[c].mNumberChannels = 1; abl->mBuffers[c].mDataByteSize = n * sizeof(float); abl->mBuffers[c].mData = h->output[c].data(); }
    AudioUnitRenderActionFlags flags = 0;
    OSStatus st = AudioUnitRender(h->unit, &flags, &h->ts, 0, n, abl);
    h->ts.mSampleTime += n;
    if (st != noErr) return audio; // mantém o áudio original em caso de erro
    for (int c = 0; c < h->chans; c++) {
        float *y = reinterpret_cast<float *>(audio->data[c]);
        if (y) memcpy(y, abl->mBuffers[c].mData, n * sizeof(float));
    }
    return audio;
}

// ---- janelas
std::map<obs_source_t *, NSWindow *> g_windows;

NSView *customView(AudioUnit unit) {
    UInt32 size = 0; Boolean writable = false;
    if (AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &size, &writable) != noErr || size == 0) return nil;
    std::vector<uint8_t> mem(size);
    auto *info = reinterpret_cast<AudioUnitCocoaViewInfo *>(mem.data());
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, info, &size) != noErr) return nil;
    NSURL *url = (__bridge NSURL *)info->mCocoaAUViewBundleLocation;
    NSString *cls = (__bridge NSString *)info->mCocoaAUViewClass[0];
    NSBundle *b = [NSBundle bundleWithURL:url];
    Class factoryClass = [b classNamed:cls];
    if (!factoryClass) return nil;
    id factory = [[factoryClass alloc] init];
    SEL sel = NSSelectorFromString(@"uiViewForAudioUnit:withSize:");
    if (![factory respondsToSelector:sel]) return nil;
    NSView *(*fn)(id, SEL, AudioUnit, NSSize) = (NSView * (*)(id, SEL, AudioUnit, NSSize)) [factory methodForSelector:sel];
    return fn(factory, sel, unit, NSMakeSize(480, 360));
}
}

namespace AudioUnitHost {
void registerType() {
    static obs_source_info info{};
    info.id = "wtv_au_filter";
    info.type = OBS_SOURCE_TYPE_FILTER;
    info.output_flags = OBS_SOURCE_AUDIO;
    info.get_name = [](void *) { return "Audio Unit"; };
    info.create = create; info.destroy = destroy; info.update = update; info.filter_audio = filterAudio;
    obs_register_source_s(&info, sizeof info);
}

json catalogue() {
    json out = json::array();
    for (UInt32 type : {(UInt32)kAudioUnitType_Effect, (UInt32)kAudioUnitType_MusicEffect}) {
        AudioComponentDescription search{type, 0, 0, 0, 0};
        for (AudioComponent c = AudioComponentFindNext(nullptr, &search); c; c = AudioComponentFindNext(c, &search)) {
            AudioComponentDescription d{}; if (AudioComponentGetDescription(c, &d) != noErr) continue;
            CFStringRef name = nullptr; AudioComponentCopyName(c, &name);
            std::string full = name ? [(__bridge NSString *)name UTF8String] : "";
            if (name) CFRelease(name);
            std::string manu = full, nm = full;
            size_t p = full.find(": ");
            if (p != std::string::npos) { manu = full.substr(0, p); nm = full.substr(p + 2); }
            out.push_back({{"id", "au:" + fourcc(d.componentType) + ":" + fourcc(d.componentSubType) + ":" + fourcc(d.componentManufacturer)}, {"name", nm}, {"manufacturer", manu}});
        }
    }
    return out;
}

bool isAU(obs_source_t *f) { return f && std::string(obs_source_get_id(f)) == "wtv_au_filter"; }

json params(obs_source_t *f) {
    auto *h = static_cast<Host *>(obs_obj_get_data(f));
    json props = json::array(), values = json::object();
    if (!h || !h->unit) return {{"properties", props}, {"values", values}};
    UInt32 size = 0; Boolean w = false;
    if (AudioUnitGetPropertyInfo(h->unit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &size, &w) != noErr) return {{"properties", props}, {"values", values}};
    std::vector<AudioUnitParameterID> ids(size / sizeof(AudioUnitParameterID));
    AudioUnitGetProperty(h->unit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, ids.data(), &size);
    for (auto pid : ids) {
        AudioUnitParameterInfo pi{}; UInt32 ps = sizeof pi;
        if (AudioUnitGetProperty(h->unit, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global, pid, &pi, &ps) != noErr) continue;
        std::string name = (pi.flags & kAudioUnitParameterFlag_HasCFNameString) && pi.cfNameString ? [(__bridge NSString *)pi.cfNameString UTF8String] : std::string(pi.name);
        AudioUnitParameterValue v = 0; AudioUnitGetParameter(h->unit, pid, kAudioUnitScope_Global, 0, &v);
        std::string key = "p" + std::to_string(pid);
        props.push_back({{"name", key}, {"description", name}, {"type", "float"}, {"min", pi.minValue}, {"max", pi.maxValue}, {"step", (pi.maxValue - pi.minValue) / 1000.0}});
        values[key] = v;
    }
    return {{"properties", props}, {"values", values}};
}

bool setParams(obs_source_t *f, const json &params) {
    auto *h = static_cast<Host *>(obs_obj_get_data(f));
    if (!h || !h->unit || !params.is_object()) return false;
    for (auto &[k, v] : params.items()) {
        if (k.size() < 2 || k[0] != 'p' || !v.is_number()) continue;
        AudioUnitSetParameter(h->unit, (AudioUnitParameterID)std::stoul(k.substr(1)), kAudioUnitScope_Global, 0, v.get<float>(), 0);
    }
    return true;
}

void openWindow(obs_source_t *f, const std::string &title) {
    auto *h = static_cast<Host *>(obs_obj_get_data(f));
    if (!h || !h->unit) return;
    AudioUnit unit = h->unit;
    NSString *t = [NSString stringWithUTF8String:title.c_str()];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (NSWindow *w = g_windows[f]) { [w makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; return; }
        NSView *v = customView(unit);
        if (!v) v = [[AUGenericView alloc] initWithAudioUnit:unit];
        NSSize size = v.fittingSize;
        if (size.width < 320 || size.height < 200) size = NSMakeSize(MAX(size.width, 560), MAX(size.height, 420));
        v.frame = NSMakeRect(0, 0, size.width, size.height);
        v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height) styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable) backing:NSBackingStoreBuffered defer:NO];
        w.title = t; w.releasedWhenClosed = NO; w.contentView = v;
        if (!g_auDelegate) g_auDelegate = [WTVAUWindowDelegate new];
        w.delegate = g_auDelegate;
        [w center]; [w makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
        g_windows[f] = w;
    });
}

void closeWindow(obs_source_t *f) {
    // Esconde e mantém a janela viva (ver WTVAUWindowDelegate); o AU é destruído depois, com a vista já fora do ecrã.
    dispatch_async(dispatch_get_main_queue(), ^{ auto it = g_windows.find(f); if (it != g_windows.end()) { [it->second orderOut:nil]; } });
}
}
