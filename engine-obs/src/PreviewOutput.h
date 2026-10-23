#pragma once
#include <obs.h>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

/// Saída libobs própria que recebe os pacotes H.264 do multiview e os entrega a um sink
/// (ControlServer → /ws/preview). Converte Annex B → AVCC e extrai o avcC dos cabeçalhos.
class PreviewOutput {
public:
    using Sink = std::function<void(bool keyframe, const std::vector<uint8_t> &avcC, const uint8_t *au, size_t len, uint64_t ptsMicros)>;

    static void registerType();
    bool start(video_t *video, const std::string &encoderId, int bitrateKbps, Sink sink);
    void stop();

private:
    static void *create(obs_data_t *, obs_output_t *);
    static void destroy(void *);
    static bool startCb(void *);
    static void stopCb(void *, uint64_t);
    static void packet(void *, encoder_packet *);

    obs_output_t *output_ = nullptr;
    obs_encoder_t *encoder_ = nullptr;
    std::vector<uint8_t> avcC_;
    Sink sink_;
};
