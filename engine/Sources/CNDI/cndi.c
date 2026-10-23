#include "cndi.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char* kCandidates[] = {
    "/usr/local/lib/libndi.dylib",
    "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
    "/Library/CoreMediaIO/Plug-Ins/DAL/NDIVideoOut.plugin/Contents/Frameworks/libndi.dylib",
    NULL
};

#define LOAD(sym, field) do { api->field = dlsym(h, sym); if (!api->field) { snprintf(error_out, error_out_len, "símbolo em falta: %s", sym); dlclose(h); memset(api, 0, sizeof(*api)); return 2; } } while (0)

int cndi_load(cndi_api_t* api, const char* override_path, char* path_out, int path_out_len, char* error_out, int error_out_len) {
    memset(api, 0, sizeof(*api));
    void* h = NULL;
    const char* used = NULL;
    if (override_path && override_path[0]) { h = dlopen(override_path, RTLD_NOW | RTLD_LOCAL); used = override_path; }
    const char* env = getenv("NDI_RUNTIME_DIR_V6");
    char envPath[1024];
    if (!h && env && env[0]) { snprintf(envPath, sizeof envPath, "%s/libndi.dylib", env); h = dlopen(envPath, RTLD_NOW | RTLD_LOCAL); used = envPath; }
    for (int i = 0; !h && kCandidates[i]; i++) { h = dlopen(kCandidates[i], RTLD_NOW | RTLD_LOCAL); used = kCandidates[i]; }
    if (!h) { snprintf(error_out, error_out_len, "libndi.dylib não encontrada: %s", dlerror() ? dlerror() : "?"); return 1; }
    api->handle = h;
    LOAD("NDIlib_initialize", initialize);
    LOAD("NDIlib_destroy", destroy);
    LOAD("NDIlib_version", version);
    LOAD("NDIlib_send_create", send_create);
    LOAD("NDIlib_send_destroy", send_destroy);
    LOAD("NDIlib_send_send_video_v2", send_send_video_v2);
    LOAD("NDIlib_send_send_audio_v3", send_send_audio_v3);
    LOAD("NDIlib_send_get_no_connections", send_get_no_connections);
    LOAD("NDIlib_find_create_v2", find_create_v2);
    LOAD("NDIlib_find_destroy", find_destroy);
    LOAD("NDIlib_find_wait_for_sources", find_wait_for_sources);
    LOAD("NDIlib_find_get_current_sources", find_get_current_sources);
    LOAD("NDIlib_recv_create_v3", recv_create_v3);
    LOAD("NDIlib_recv_destroy", recv_destroy);
    LOAD("NDIlib_recv_connect", recv_connect);
    LOAD("NDIlib_recv_capture_v3", recv_capture_v3);
    LOAD("NDIlib_recv_free_video_v2", recv_free_video_v2);
    LOAD("NDIlib_recv_free_audio_v3", recv_free_audio_v3);
    LOAD("NDIlib_recv_free_metadata", recv_free_metadata);
    LOAD("NDIlib_recv_get_no_connections", recv_get_no_connections);
    snprintf(path_out, path_out_len, "%s", used ? used : "");
    error_out[0] = 0;
    return 0;
}

void cndi_unload(cndi_api_t* api) {
    if (api->handle) dlclose(api->handle);
    memset(api, 0, sizeof(*api));
}
