// Prova de conceito WTV sobre a libobs: arranca o motor, compõe uma cena com uma fonte de cor
// e um texto, codifica com VideoToolbox H.264 + AAC e grava N segundos num ficheiro via ffmpeg_muxer.
#include <obs.h>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>

static void log_cb(int level, const char *fmt, va_list args, void *) {
    if (level > LOG_INFO) return;
    vfprintf(stderr, fmt, args);
    fputc('\n', stderr);
}

static std::string find_encoder(const char *needle) {
    const char *id = nullptr;
    for (size_t i = 0; obs_enum_encoder_types(i, &id); i++)
        if (strstr(id, needle) && obs_get_encoder_type(id) == OBS_ENCODER_VIDEO) return id;
    return "";
}

int main(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "uso: wtv-poc <dir plugins> <libobs/data> <ficheiro saída> <segundos> [módulo gráfico]\n"); return 2; }
    const std::string plugins = argv[1], data = argv[2], out = argv[3];
    const int seconds = atoi(argv[4]);
    const char *gfx = argc > 5 ? argv[5] : "libobs-opengl";

    base_set_log_handler(log_cb, nullptr);
    if (!obs_startup("en-US", nullptr, nullptr)) { fprintf(stderr, "obs_startup falhou\n"); return 1; }

    obs_add_data_path((data + "/").c_str());
    obs_video_info ovi{};
    ovi.graphics_module = gfx;
    ovi.fps_num = 50; ovi.fps_den = 1;
    ovi.base_width = 1920; ovi.base_height = 1080;
    ovi.output_width = 1920; ovi.output_height = 1080;
    ovi.output_format = VIDEO_FORMAT_NV12;
    ovi.gpu_conversion = true;
    ovi.colorspace = VIDEO_CS_709; ovi.range = VIDEO_RANGE_PARTIAL;
    ovi.scale_type = OBS_SCALE_BICUBIC;
    if (obs_reset_video(&ovi) != OBS_VIDEO_SUCCESS) { fprintf(stderr, "obs_reset_video falhou\n"); return 1; }
    obs_audio_info oai{48000, SPEAKERS_STEREO};
    if (!obs_reset_audio(&oai)) { fprintf(stderr, "obs_reset_audio falhou\n"); return 1; }

    obs_add_module_path((plugins + "/%module%.plugin/Contents/MacOS").c_str(),
                        (plugins + "/%module%.plugin/Contents/Resources").c_str());
    obs_load_all_modules();
    obs_post_load_modules();

    obs_data_t *cs = obs_data_create();
    obs_data_set_int(cs, "color", 0xFFC06020); // ABGR: azul obs_data_set_int(cs, "width", 1920); obs_data_set_int(cs, "height", 1080);
    obs_source_t *color = obs_source_create("color_source_v3", "fundo", cs, nullptr);
    obs_data_t *ts = obs_data_create();
    obs_data_set_string(ts, "text", "WTV Studio sobre libobs");
    obs_data_t *font = obs_data_create();
    obs_data_set_string(font, "face", "Helvetica"); obs_data_set_int(font, "size", 96);
    obs_data_set_obj(ts, "font", font);
    obs_source_t *text = obs_source_create("text_ft2_source_v2", "titulo", ts, nullptr);

    obs_scene_t *scene = obs_scene_create("program");
    obs_scene_add(scene, color);
    obs_sceneitem_t *ti = obs_scene_add(scene, text);
    vec2 pos{200, 450}; obs_sceneitem_set_pos(ti, &pos);
    obs_set_output_source(0, obs_scene_get_source(scene));

    std::string venc_id = find_encoder("avc");
    if (venc_id.empty()) venc_id = "obs_x264";
    fprintf(stderr, "codificador de vídeo: %s\n", venc_id.c_str());
    obs_data_t *vs = obs_data_create();
    obs_data_set_int(vs, "bitrate", 6000); obs_data_set_string(vs, "rate_control", "CBR");
    obs_data_set_int(vs, "keyint_sec", 2);
    obs_encoder_t *venc = obs_video_encoder_create(venc_id.c_str(), "h264", vs, nullptr);
    obs_encoder_t *aenc = obs_audio_encoder_create("CoreAudio_AAC", "aac", nullptr, 0, nullptr);
    if (!aenc) aenc = obs_audio_encoder_create("ffmpeg_aac", "aac", nullptr, 0, nullptr);
    obs_encoder_set_video(venc, obs_get_video());
    obs_encoder_set_audio(aenc, obs_get_audio());

    obs_data_t *os = obs_data_create();
    obs_data_set_string(os, "path", out.c_str());
    obs_output_t *output = obs_output_create("ffmpeg_muxer", "gravacao", os, nullptr);
    obs_output_set_video_encoder(output, venc);
    obs_output_set_audio_encoder(output, aenc, 0);
    if (!obs_output_start(output)) { fprintf(stderr, "obs_output_start falhou: %s\n", obs_output_get_last_error(output)); return 1; }

    auto t0 = std::chrono::steady_clock::now();
    std::this_thread::sleep_for(std::chrono::seconds(seconds));
    obs_output_stop(output);
    while (obs_output_active(output)) std::this_thread::sleep_for(std::chrono::milliseconds(50));
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
    fprintf(stderr, "gravou %s em %lld ms; frames perdidos no render: %u, lag: %u\n", out.c_str(), (long long)ms,
            obs_get_lagged_frames(), obs_get_total_frames() ? obs_get_lagged_frames() : 0);

    obs_set_output_source(0, nullptr);
    obs_output_release(output); obs_encoder_release(venc); obs_encoder_release(aenc);
    obs_scene_release(scene);
    obs_source_release(text); obs_source_release(color);
    obs_wait_for_destroy_queue(); // as destruições são diferidas para a thread de tarefas; esperar antes do shutdown
    obs_data_release(cs); obs_data_release(ts); obs_data_release(font); obs_data_release(vs); obs_data_release(os);
    obs_shutdown();
    return 0;
}
