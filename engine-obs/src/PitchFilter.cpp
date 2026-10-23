// Filtro de afinação (pitch shift) para a libobs: baixa/sobe a afinação sem mudar a velocidade.
// Uso principal: 440 Hz → 432 Hz (−31,77 cents). Método SoundTouch-like: transposição por reamostragem
// seguida de time-stretch WSOLA (overlap-add com procura de correlação), por canal, em float 48 kHz.
#include "PitchFilter.h"
#include <obs.h>
#include <cmath>
#include <cstring>
#include <vector>

namespace {
constexpr int SEQ_MS = 40, SEEK_MS = 15, OVERLAP_MS = 8;

struct Channel {
    std::vector<float> in;      // amostras já transpostas à espera do WSOLA
    std::vector<float> prevTail; // cauda do segmento anterior (overlap)
    double readPos = 0;          // posição fraccionária do reamostrador na entrada original
    std::vector<float> src;      // entrada original pendente para o reamostrador
};

struct Pitch {
    obs_source_t *ctx;
    double cents = -31.766533;
    double ratio = 1.0;          // factor de afinação (432/440)
    int rate = 48000, chans = 2;
    int seq = 1920, seek = 720, overlap = 384;
    std::vector<Channel> ch;
    std::vector<float> outBuf;   // intercalado por canal → obs_audio_data planar: usamos vectores por canal
    std::vector<std::vector<float>> outPlanes;
    std::vector<float> win;
    bool bypass = false;
};

void configure(Pitch *p) {
    obs_audio_info oai{}; obs_get_audio_info(&oai);
    p->rate = (int)oai.samples_per_sec; p->chans = (int)get_audio_channels(oai.speakers);
    p->ratio = std::pow(2.0, p->cents / 1200.0);
    p->bypass = std::fabs(p->cents) < 0.01;
    p->seq = p->rate * SEQ_MS / 1000; p->seek = p->rate * SEEK_MS / 1000; p->overlap = p->rate * OVERLAP_MS / 1000;
    p->ch.assign(p->chans, Channel{});
    p->outPlanes.assign(p->chans, {});
    p->win.resize(p->overlap);
    for (int i = 0; i < p->overlap; i++) p->win[i] = (float)i / p->overlap;
}

void update(void *d, obs_data_t *s) {
    auto *p = static_cast<Pitch *>(d);
    p->cents = obs_data_get_double(s, "cents");
    configure(p);
}

void *create(obs_data_t *s, obs_source_t *ctx) { auto *p = new Pitch{ctx}; update(p, s); return p; }
void destroy(void *d) { delete static_cast<Pitch *>(d); }
void defaults(obs_data_t *s) { obs_data_set_default_double(s, "cents", -31.766533); }
obs_properties_t *properties(void *) {
    obs_properties_t *ps = obs_properties_create();
    obs_properties_add_float_slider(ps, "cents", "Desvio (cents): −31,77 = 432 Hz", -200.0, 200.0, 0.01);
    return ps;
}

// Transposição: lê a entrada a passo `ratio` (ratio < 1 → mais amostras, tom mais grave) com interpolação linear.
void transpose(Pitch *p, Channel &c, const float *x, size_t n) {
    c.src.insert(c.src.end(), x, x + n);
    size_t avail = c.src.size();
    while (c.readPos + 1 < avail) {
        size_t i = (size_t)c.readPos; float f = (float)(c.readPos - i);
        c.in.push_back(c.src[i] + (c.src[i + 1] - c.src[i]) * f);
        c.readPos += p->ratio;
    }
    size_t consumed = (size_t)c.readPos;
    if (consumed > 0) { c.src.erase(c.src.begin(), c.src.begin() + consumed); c.readPos -= consumed; }
}

// WSOLA: produz segmentos de `seq` amostras avançando a entrada `seq-overlap` × tempo, com procura do melhor
// alinhamento (correlação) numa janela de ±seek para evitar cortes audíveis. tempo = 1/ratio repõe a duração.
void stretch(Pitch *p, Channel &c, std::vector<float> &out) {
    const int seq = p->seq, ov = p->overlap, seek = p->seek;
    const double tempo = 1.0 / p->ratio;
    const int skip = (int)std::lround((seq - ov) * tempo);
    size_t pos = 0;
    while (pos + seek + seq <= c.in.size()) {
        int best = 0;
        if (!c.prevTail.empty()) {
            double bestCorr = -1e30;
            for (int off = 0; off < seek; off++) {
                double corr = 0, norm = 1e-9;
                const float *cand = &c.in[pos + off];
                for (int i = 0; i < ov; i += 2) { corr += cand[i] * c.prevTail[i]; norm += cand[i] * cand[i]; }
                corr /= std::sqrt(norm);
                if (corr > bestCorr) { bestCorr = corr; best = off; }
            }
        }
        const float *seg = &c.in[pos + best];
        if (c.prevTail.empty()) out.insert(out.end(), seg, seg + (seq - ov));
        else {
            for (int i = 0; i < ov; i++) out.push_back(c.prevTail[i] * (1 - p->win[i]) + seg[i] * p->win[i]);
            out.insert(out.end(), seg + ov, seg + (seq - ov));
        }
        c.prevTail.assign(seg + (seq - ov), seg + seq);
        pos += skip;
    }
    if (pos > 0) c.in.erase(c.in.begin(), c.in.begin() + pos);
}

obs_audio_data *filterAudio(void *d, obs_audio_data *audio) {
    auto *p = static_cast<Pitch *>(d);
    if (p->bypass) return audio;
    size_t n = audio->frames;
    for (int ch = 0; ch < p->chans; ch++) {
        auto &plane = p->outPlanes[ch];
        const float *x = reinterpret_cast<const float *>(audio->data[ch]);
        if (!x) continue;
        transpose(p, p->ch[ch], x, n);
        stretch(p, p->ch[ch], plane);
    }
    // Entrega sempre `n` amostras: a latência inicial é preenchida com silêncio e depois mantém-se constante.
    for (int ch = 0; ch < p->chans; ch++) {
        auto &plane = p->outPlanes[ch];
        float *y = reinterpret_cast<float *>(audio->data[ch]);
        if (!y) continue;
        if (plane.size() >= n) { memcpy(y, plane.data(), n * sizeof(float)); plane.erase(plane.begin(), plane.begin() + n); }
        else { memset(y, 0, n * sizeof(float)); }
        if (plane.size() > (size_t)p->rate / 2) plane.erase(plane.begin(), plane.begin() + (plane.size() - p->rate / 4)); // segurança contra deriva
    }
    return audio;
}
}

void PitchFilter::registerType() {
    static obs_source_info info{};
    info.id = "wtv_pitch_filter";
    info.type = OBS_SOURCE_TYPE_FILTER;
    info.output_flags = OBS_SOURCE_AUDIO;
    info.get_name = [](void *) { return "Afinação (pitch)"; };
    info.create = create; info.destroy = destroy; info.update = update;
    info.get_defaults = defaults; info.get_properties = properties;
    info.filter_audio = filterAudio;
    obs_register_source_s(&info, sizeof info);
}
