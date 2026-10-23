#include "ObsRuntime.h"
#include <cstdio>
#include <cstring>

static void logHandler(int level, const char *fmt, va_list args, void *) {
    if (level > LOG_INFO) return;
    fprintf(stderr, "[obs] ");
    vfprintf(stderr, fmt, args);
    fputc('\n', stderr);
}

bool ObsRuntime::start(const ObsConfig &cfg) {
    cfg_ = cfg;
    base_set_log_handler(logHandler, nullptr);
    if (!obs_startup("en-US", nullptr, nullptr)) return false;
    obs_add_data_path((cfg.dataDir + "/").c_str());
    if (!resetVideo(cfg.width, cfg.height, cfg.fpsNum, cfg.fpsDen)) return false;
    obs_audio_info oai{48000, SPEAKERS_STEREO};
    if (!obs_reset_audio(&oai)) return false;
    obs_add_module_path((cfg.pluginsDir + "/%module%.plugin/Contents/MacOS").c_str(),
                        (cfg.pluginsDir + "/%module%.plugin/Contents/Resources").c_str());
    obs_load_all_modules();
    obs_post_load_modules();
    started_ = true;
    return true;
}

bool ObsRuntime::resetVideo(int width, int height, int fpsNum, int fpsDen) {
    obs_video_info ovi{};
    ovi.graphics_module = cfg_.graphicsModule.c_str();
    ovi.fps_num = fpsNum; ovi.fps_den = fpsDen;
    ovi.base_width = width; ovi.base_height = height;
    ovi.output_width = width; ovi.output_height = height;
    ovi.output_format = VIDEO_FORMAT_NV12;
    ovi.gpu_conversion = true;
    ovi.colorspace = VIDEO_CS_709; ovi.range = VIDEO_RANGE_PARTIAL;
    ovi.scale_type = OBS_SCALE_BICUBIC;
    int r = obs_reset_video(&ovi);
    if (r != OBS_VIDEO_SUCCESS) { fprintf(stderr, "obs_reset_video: %d\n", r); return false; }
    cfg_.width = width; cfg_.height = height; cfg_.fpsNum = fpsNum; cfg_.fpsDen = fpsDen;
    return true;
}

std::string ObsRuntime::videoEncoderId() const {
    const char *id = nullptr;
    for (size_t i = 0; obs_enum_encoder_types(i, &id); i++)
        if (strstr(id, "videotoolbox") && strstr(id, "avc") && obs_get_encoder_type(id) == OBS_ENCODER_VIDEO) return id;
    return "obs_x264";
}

void ObsRuntime::stop() {
    if (!started_) return;
    obs_set_output_source(0, nullptr);
    obs_wait_for_destroy_queue();
    obs_shutdown();
    started_ = false;
}
