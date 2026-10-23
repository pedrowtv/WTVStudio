#include "PreviewOutput.h"
#include <obs-avc.h>
#include <cstring>

struct PreviewCtx { obs_output_t *output; PreviewOutput *owner; };

void PreviewOutput::registerType() {
    static obs_output_info info{};
    info.id = "wtv_preview_output";
    info.flags = OBS_OUTPUT_VIDEO | OBS_OUTPUT_ENCODED;
    info.get_name = [](void *) { return "WTV preview"; };
    info.create = create; info.destroy = destroy; info.start = startCb; info.stop = stopCb; info.encoded_packet = packet;
    info.encoded_video_codecs = "h264";
    obs_register_output_s(&info, sizeof info);
}

void *PreviewOutput::create(obs_data_t *, obs_output_t *output) { return new PreviewCtx{output, nullptr}; }
void PreviewOutput::destroy(void *d) { delete static_cast<PreviewCtx *>(d); }

bool PreviewOutput::startCb(void *d) {
    auto *ctx = static_cast<PreviewCtx *>(d);
    if (!obs_output_can_begin_data_capture(ctx->output, 0)) return false;
    if (!obs_output_initialize_encoders(ctx->output, 0)) return false;
    return obs_output_begin_data_capture(ctx->output, 0);
}

void PreviewOutput::stopCb(void *d, uint64_t) { obs_output_end_data_capture(static_cast<PreviewCtx *>(d)->output); }

void PreviewOutput::packet(void *d, encoder_packet *pkt) {
    auto *ctx = static_cast<PreviewCtx *>(d);
    PreviewOutput *self = ctx->owner;
    if (!self || !self->sink_ || pkt->type != OBS_ENCODER_VIDEO) return;
    if (self->avcC_.empty()) {
        uint8_t *hdr = nullptr; size_t sz = 0;
        if (obs_encoder_get_extra_data(self->encoder_, &hdr, &sz) && sz) {
            uint8_t *avcc = nullptr;
            size_t n = obs_parse_avc_header(&avcc, hdr, sz);
            if (n) { self->avcC_.assign(avcc, avcc + n); bfree(avcc); }
        }
    }
    encoder_packet avcc{};
    obs_parse_avc_packet(&avcc, pkt); // Annex B → AVCC (aloca avcc.data)
    uint64_t pts = (uint64_t)(pkt->pts * 1000000.0 * pkt->timebase_num / pkt->timebase_den);
    self->sink_(pkt->keyframe, self->avcC_, avcc.data, avcc.size, pts);
    obs_encoder_packet_release(&avcc);
}

bool PreviewOutput::start(video_t *video, const std::string &encoderId, int bitrateKbps, Sink sink) {
    sink_ = std::move(sink);
    obs_data_t *es = obs_data_create();
    obs_data_set_int(es, "bitrate", bitrateKbps);
    obs_data_set_string(es, "rate_control", "CBR");
    obs_data_set_int(es, "keyint_sec", 1);
    obs_data_set_string(es, "profile", "main");
    obs_data_set_bool(es, "bframes", false);
    obs_data_set_string(es, "preset", "ultrafast"); obs_data_set_string(es, "tune", "zerolatency"); // só x264
    encoder_ = obs_video_encoder_create(encoderId.c_str(), "wtv-preview-h264", es, nullptr);
    obs_data_release(es);
    if (!encoder_) return false;
    obs_encoder_set_video(encoder_, video);
    output_ = obs_output_create("wtv_preview_output", "wtv-preview", nullptr, nullptr);
    if (!output_) return false;
    static_cast<PreviewCtx *>(obs_obj_get_data(output_))->owner = this;
    obs_output_set_media(output_, video, obs_get_audio());
    obs_output_set_video_encoder(output_, encoder_);
    return obs_output_start(output_);
}

void PreviewOutput::stop() {
    if (output_) { obs_output_stop(output_); obs_output_release(output_); output_ = nullptr; }
    if (encoder_) { obs_encoder_release(encoder_); encoder_ = nullptr; }
}
