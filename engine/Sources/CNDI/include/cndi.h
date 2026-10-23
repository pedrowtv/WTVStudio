// Shim C para a libndi (carregada com dlopen; D17). Só as estruturas e funções usadas pelo motor.
// Layouts copiados do NDI SDK 6 (Processing.NDI.structs.h / Processing.NDI.Send.h).
#ifndef CNDI_H
#define CNDI_H
#include <stdbool.h>
#include <stdint.h>

#define CNDI_FOURCC(a,b,c,d) ((uint32_t)(a) | ((uint32_t)(b) << 8) | ((uint32_t)(c) << 16) | ((uint32_t)(d) << 24))
static const uint32_t CNDI_FOURCC_BGRA = CNDI_FOURCC('B','G','R','A');
static const uint32_t CNDI_FOURCC_UYVY = CNDI_FOURCC('U','Y','V','Y');
static const uint32_t CNDI_FOURCC_FLTP = CNDI_FOURCC('F','L','T','p');
static const uint32_t CNDI_FOURCC_BGRX = CNDI_FOURCC('B','G','R','X');
static const int CNDI_FRAME_PROGRESSIVE = 1;

typedef struct { const char* p_ndi_name; const char* p_groups; bool clock_video; bool clock_audio; } cndi_send_create_t;

/* Ordem exacta do NDI SDK 6 (NDIlib_video_frame_v2_t): xres, yres, FourCC, frame_rate_N, frame_rate_D,
   picture_aspect_ratio, frame_format_type, timecode, p_data, line_stride_in_bytes, p_metadata, timestamp. */
typedef struct {
    int xres, yres;
    uint32_t FourCC;
    int frame_rate_N, frame_rate_D;
    float picture_aspect_ratio;
    int frame_format_type;
    int64_t timecode;
    uint8_t* p_data;
    int line_stride_in_bytes;
    const char* p_metadata;
    int64_t timestamp;
} cndi_video_frame_v2_t;
_Static_assert(sizeof(cndi_video_frame_v2_t) == 72, "cndi_video_frame_v2_t tem de ter 72 bytes como no SDK");


typedef struct {
    int sample_rate;
    int no_channels;
    int no_samples;
    int64_t timecode;
    uint32_t FourCC;
    float* p_data;
    int channel_stride_in_bytes;
    const char* p_metadata;
    int64_t timestamp;
} cndi_audio_frame_v3_t;
_Static_assert(sizeof(cndi_audio_frame_v3_t) == 64, "cndi_audio_frame_v3_t tem de ter 64 bytes como no SDK");

typedef struct { const char* p_ndi_name; const char* p_url_address; } cndi_source_t;

/* Descoberta (NDIlib_find_create_t) */
typedef struct { bool show_local_sources; const char* p_groups; const char* p_extra_ips; } cndi_find_create_t;

/* Recepção (NDIlib_recv_create_v3_t) */
typedef struct {
    cndi_source_t source_to_connect_to;
    int color_format;      /* 1 = BGRX_BGRA, 0 = UYVY_BGRA, 100 = fastest */
    int bandwidth;         /* 100 = highest, 10 = audio only, 0 = lowest, -10 metadata only */
    bool allow_video_fields;
    const char* p_ndi_recv_name;
} cndi_recv_create_v3_t;

typedef struct { int64_t timecode; char* p_data; int length; } cndi_metadata_frame_t;

static const int CNDI_RECV_COLOR_BGRX_BGRA = 0; /* NDIlib_recv_color_format_BGRX_BGRA */
static const int CNDI_RECV_BANDWIDTH_HIGHEST = 100;
static const int CNDI_RECV_BANDWIDTH_LOWEST = 0;
static const int CNDI_FRAME_TYPE_NONE = 0, CNDI_FRAME_TYPE_VIDEO = 1, CNDI_FRAME_TYPE_AUDIO = 2, CNDI_FRAME_TYPE_METADATA = 3, CNDI_FRAME_TYPE_ERROR = 4, CNDI_FRAME_TYPE_STATUS_CHANGE = 100;

typedef void* cndi_send_instance_t;
typedef void* cndi_find_instance_t;
typedef void* cndi_recv_instance_t;

typedef struct {
    void* handle;
    bool (*initialize)(void);
    void (*destroy)(void);
    const char* (*version)(void);
    cndi_send_instance_t (*send_create)(const cndi_send_create_t*);
    void (*send_destroy)(cndi_send_instance_t);
    void (*send_send_video_v2)(cndi_send_instance_t, const cndi_video_frame_v2_t*);
    void (*send_send_audio_v3)(cndi_send_instance_t, const cndi_audio_frame_v3_t*);
    int (*send_get_no_connections)(cndi_send_instance_t, uint32_t timeout_ms);
    /* descoberta */
    cndi_find_instance_t (*find_create_v2)(const cndi_find_create_t*);
    void (*find_destroy)(cndi_find_instance_t);
    bool (*find_wait_for_sources)(cndi_find_instance_t, uint32_t timeout_ms);
    const cndi_source_t* (*find_get_current_sources)(cndi_find_instance_t, uint32_t* no_sources);
    /* recepção */
    cndi_recv_instance_t (*recv_create_v3)(const cndi_recv_create_v3_t*);
    void (*recv_destroy)(cndi_recv_instance_t);
    void (*recv_connect)(cndi_recv_instance_t, const cndi_source_t*);
    int (*recv_capture_v3)(cndi_recv_instance_t, cndi_video_frame_v2_t*, cndi_audio_frame_v3_t*, cndi_metadata_frame_t*, uint32_t timeout_ms);
    void (*recv_free_video_v2)(cndi_recv_instance_t, const cndi_video_frame_v2_t*);
    void (*recv_free_audio_v3)(cndi_recv_instance_t, const cndi_audio_frame_v3_t*);
    void (*recv_free_metadata)(cndi_recv_instance_t, const cndi_metadata_frame_t*);
    int (*recv_get_no_connections)(cndi_recv_instance_t);
} cndi_api_t;

/// Procura e carrega a libndi.dylib. Devolve 0 em sucesso; `path_out` recebe o caminho usado.
int cndi_load(cndi_api_t* api, const char* override_path, char* path_out, int path_out_len, char* error_out, int error_out_len);
void cndi_unload(cndi_api_t* api);
#endif
