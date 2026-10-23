#include "NDI.h"
extern "C" {
#include "cndi/cndi.h"
}
#include <util/platform.h>
#include <atomic>
#include <cstring>
#include <thread>
#include <vector>

namespace {
cndi_api_t g_api{};
bool g_loaded = false;
std::string g_version;
cndi_find_instance_t g_find = nullptr;

// ---------------- fonte ----------------
struct NdiSource {
    obs_source_t *source;
    std::string name;
    bool lowBandwidth = false;
    std::thread thread;
    std::atomic<bool> stop{false};
    std::atomic<int> generation{0};
};

void sourceThread(NdiSource *s) {
    int gen = s->generation.load();
    cndi_source_t src{s->name.c_str(), nullptr};
    cndi_recv_create_v3_t create{src, CNDI_RECV_COLOR_BGRX_BGRA, s->lowBandwidth ? CNDI_RECV_BANDWIDTH_LOWEST : CNDI_RECV_BANDWIDTH_HIGHEST, false, "WTV Studio"};
    cndi_recv_instance_t recv = g_api.recv_create_v3(&create);
    if (!recv) { blog(LOG_WARNING, "NDI: recv_create falhou para '%s'", s->name.c_str()); return; }
    std::vector<float> scratch;
    while (!s->stop && s->generation == gen) {
        cndi_video_frame_v2_t v{}; cndi_audio_frame_v3_t a{}; cndi_metadata_frame_t m{};
        int t = g_api.recv_capture_v3(recv, &v, &a, &m, 100);
        if (t == CNDI_FRAME_TYPE_VIDEO) {
            obs_source_frame f{};
            f.data[0] = v.p_data; f.linesize[0] = (uint32_t)v.line_stride_in_bytes;
            f.width = (uint32_t)v.xres; f.height = (uint32_t)v.yres;
            f.format = v.FourCC == CNDI_FOURCC_BGRX ? VIDEO_FORMAT_BGRX : VIDEO_FORMAT_BGRA;
            static int logged = 0;
            if (logged++ == 0) { char cc[5] = {(char)(v.FourCC & 0xFF), (char)(v.FourCC >> 8), (char)(v.FourCC >> 16), (char)(v.FourCC >> 24), 0}; blog(LOG_INFO, "NDI in 1.º frame %s %dx%d stride %d %d/%d fps", cc, v.xres, v.yres, v.line_stride_in_bytes, v.frame_rate_N, v.frame_rate_D); }
            f.timestamp = os_gettime_ns();
            f.full_range = true;
            obs_source_output_video(s->source, &f);
            g_api.recv_free_video_v2(recv, &v);
        } else if (t == CNDI_FRAME_TYPE_AUDIO) {
            obs_source_audio oa{};
            int ch = a.no_channels < 1 ? 1 : a.no_channels > 2 ? 2 : a.no_channels;
            for (int c = 0; c < ch; c++) oa.data[c] = reinterpret_cast<const uint8_t *>(a.p_data) + (size_t)c * a.channel_stride_in_bytes;
            oa.frames = (uint32_t)a.no_samples;
            oa.speakers = ch == 1 ? SPEAKERS_MONO : SPEAKERS_STEREO;
            oa.format = AUDIO_FORMAT_FLOAT_PLANAR;
            oa.samples_per_sec = (uint32_t)a.sample_rate;
            oa.timestamp = os_gettime_ns();
            obs_source_output_audio(s->source, &oa);
            g_api.recv_free_audio_v3(recv, &a);
        } else if (t == CNDI_FRAME_TYPE_METADATA) {
            g_api.recv_free_metadata(recv, &m);
        }
    }
    g_api.recv_destroy(recv);
}

void sourceStart(NdiSource *s) {
    if (s->thread.joinable()) { s->generation++; s->thread.join(); }
    s->stop = false;
    if (s->name.empty()) return;
    s->thread = std::thread(sourceThread, s);
}

void *sourceCreate(obs_data_t *settings, obs_source_t *source) {
    auto *s = new NdiSource{source};
    s->name = obs_data_get_string(settings, "source_name");
    s->lowBandwidth = obs_data_get_bool(settings, "low_bandwidth");
    sourceStart(s);
    return s;
}

void sourceDestroy(void *d) {
    auto *s = static_cast<NdiSource *>(d);
    s->stop = true; s->generation++;
    if (s->thread.joinable()) s->thread.join();
    delete s;
}

void sourceUpdate(void *d, obs_data_t *settings) {
    auto *s = static_cast<NdiSource *>(d);
    std::string name = obs_data_get_string(settings, "source_name");
    bool low = obs_data_get_bool(settings, "low_bandwidth");
    if (name == s->name && low == s->lowBandwidth) return;
    s->name = name; s->lowBandwidth = low;
    sourceStart(s);
}

// ---------------- saída ----------------
struct NdiOutput {
    obs_output_t *output;
    cndi_send_instance_t send = nullptr;
    int fpsN = 50, fpsD = 1;
    std::vector<float> audioScratch;
};

void *outputCreate(obs_data_t *, obs_output_t *output) { return new NdiOutput{output}; }
void outputDestroy(void *d) { delete static_cast<NdiOutput *>(d); }

bool outputStart(void *d) {
    auto *o = static_cast<NdiOutput *>(d);
    obs_data_t *st = obs_output_get_settings(o->output);
    std::string name = obs_data_get_string(st, "ndi_name");
    obs_data_release(st);
    if (name.empty()) name = "WTV Studio";
    obs_video_info ovi{}; obs_get_video_info(&ovi);
    o->fpsN = (int)ovi.fps_num; o->fpsD = (int)ovi.fps_den;
    video_scale_info vs{VIDEO_FORMAT_BGRA, ovi.output_width, ovi.output_height, VIDEO_RANGE_FULL, VIDEO_CS_SRGB};
    obs_output_set_video_conversion(o->output, &vs);
    audio_convert_info ac{48000, AUDIO_FORMAT_FLOAT_PLANAR, SPEAKERS_STEREO, false};
    obs_output_set_audio_conversion(o->output, &ac);
    cndi_send_create_t create{name.c_str(), nullptr, false, false};
    o->send = g_api.send_create(&create);
    if (!o->send) { obs_output_set_last_error(o->output, "NDI send_create falhou"); return false; }
    if (!obs_output_begin_data_capture(o->output, 0)) { g_api.send_destroy(o->send); o->send = nullptr; return false; }
    return true;
}

void outputStop(void *d, uint64_t) {
    auto *o = static_cast<NdiOutput *>(d);
    obs_output_end_data_capture(o->output);
    if (o->send) { g_api.send_destroy(o->send); o->send = nullptr; }
}

void outputRawVideo(void *d, struct video_data *frame) {
    auto *o = static_cast<NdiOutput *>(d);
    if (!o->send) return;
    obs_video_info ovi{}; obs_get_video_info(&ovi);
    cndi_video_frame_v2_t v{};
    v.xres = (int)ovi.output_width; v.yres = (int)ovi.output_height;
    v.FourCC = CNDI_FOURCC_BGRA; v.frame_rate_N = o->fpsN; v.frame_rate_D = o->fpsD;
    v.picture_aspect_ratio = 0; v.frame_format_type = CNDI_FRAME_PROGRESSIVE;
    v.timecode = INT64_MAX; // NDIlib_send_timecode_synthesize
    v.p_data = frame->data[0]; v.line_stride_in_bytes = (int)frame->linesize[0];
    g_api.send_send_video_v2(o->send, &v);
}

void outputRawAudio(void *d, struct audio_data *frames) {
    auto *o = static_cast<NdiOutput *>(d);
    if (!o->send) return;
    size_t n = frames->frames;
    if (o->audioScratch.size() < n * 2) o->audioScratch.resize(n * 2);
    memcpy(o->audioScratch.data(), frames->data[0], n * sizeof(float));
    memcpy(o->audioScratch.data() + n, frames->data[1] ? frames->data[1] : frames->data[0], n * sizeof(float));
    cndi_audio_frame_v3_t a{};
    a.sample_rate = 48000; a.no_channels = 2; a.no_samples = (int)n; a.timecode = INT64_MAX;
    a.FourCC = CNDI_FOURCC_FLTP; a.p_data = o->audioScratch.data(); a.channel_stride_in_bytes = (int)(n * sizeof(float));
    g_api.send_send_audio_v3(o->send, &a);
}
} // namespace

namespace NDI {
bool load() {
    if (g_loaded) return true;
    char path[512] = {0}, err[256] = {0};
    if (cndi_load(&g_api, getenv("WTV_NDI_PATH"), path, sizeof path, err, sizeof err) != 0) { blog(LOG_INFO, "NDI indisponível: %s", err); return false; }
    if (!g_api.initialize()) { blog(LOG_WARNING, "NDI: initialize falhou"); return false; }
    g_version = g_api.version() ? g_api.version() : "?";
    blog(LOG_INFO, "NDI carregado: %s (%s)", g_version.c_str(), path);
    g_loaded = true;
    return true;
}
bool available() { return g_loaded; }
std::string version() { return g_version; }

void registerTypes() {
    if (!g_loaded) return;
    static obs_source_info src{};
    src.id = "wtv_ndi_source";
    src.type = OBS_SOURCE_TYPE_INPUT;
    src.output_flags = OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_AUDIO | OBS_SOURCE_DO_NOT_DUPLICATE;
    src.get_name = [](void *) { return "NDI"; };
    src.create = sourceCreate; src.destroy = sourceDestroy; src.update = sourceUpdate;
    obs_register_source_s(&src, sizeof src);
    static obs_output_info out{};
    out.id = "wtv_ndi_output";
    out.flags = OBS_OUTPUT_AV;
    out.get_name = [](void *) { return "NDI"; };
    out.create = outputCreate; out.destroy = outputDestroy; out.start = outputStart; out.stop = outputStop;
    out.raw_video = outputRawVideo; out.raw_audio = outputRawAudio;
    obs_register_output_s(&out, sizeof out);
}

json discover(unsigned waitMs) {
    json out = json::array();
    if (!g_loaded) return out;
    if (!g_find) { cndi_find_create_t c{true, nullptr, nullptr}; g_find = g_api.find_create_v2(&c); }
    if (!g_find) return out;
    if (waitMs) g_api.find_wait_for_sources(g_find, waitMs);
    uint32_t n = 0;
    const cndi_source_t *list = g_api.find_get_current_sources(g_find, &n);
    for (uint32_t i = 0; list && i < n; i++) out.push_back({{"name", list[i].p_ndi_name ? list[i].p_ndi_name : ""}, {"url", list[i].p_url_address ? list[i].p_url_address : ""}});
    return out;
}

void shutdown() {
    if (g_find) { g_api.find_destroy(g_find); g_find = nullptr; }
    if (g_loaded) { g_api.destroy(); cndi_unload(&g_api); g_loaded = false; }
}
}
