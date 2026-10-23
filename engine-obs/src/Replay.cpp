#include "Replay.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
// Estrutura interna do filtro do plugin vendorizado (engine-obs/third_party/obs-replay-source): só para ler quantos
// frames há no buffer antes e depois de um Load (o plugin não expõe esta contagem).
#include <obs-replay-source/replay.h>

void Replay::init() {
    available_ = obs_source_get_display_name("replay_source") != nullptr;
    if (available_) obs_hotkey_enable_callback_rerouting(true); // sem isto obs_hotkey_trigger_routed_callback é no-op
    bufferSeconds_ = store_.state()["replay"].value("bufferSeconds", 8);
    store_.mutate([&](json &s) { s["replay"]["status"] = available_ ? "idle" : "unavailable"; });
    if (!available_) fprintf(stderr, "replay: plugin Replay Source não carregado — replay indisponível\n");
}

void Replay::shutdown() {
    std::lock_guard l(m_);
    if (replay_) signal_handler_disconnect(obs_source_get_signal_handler(replay_), "update", onSourceUpdate, this);
    replay_ = nullptr; // sem replay_ o disarm não espera por updates (a fonte vai ser destruída pelo Switcher)
    std::vector<std::string> ids;
    for (auto &[id, a] : angles_) ids.push_back(id);
    for (auto &id : ids) disarmAngle(id);
}

std::string Replay::replayInputId() { std::lock_guard l(m_); return replayId_; }

void Replay::onSourceUpdate(void *data, calldata_t *) {
    auto *self = static_cast<Replay *>(data);
    { std::lock_guard g(self->updM_); self->updated_ = true; }
    self->updCv_.notify_all();
}

bool Replay::waitForSignal() {
    std::unique_lock g(updM_);
    return updCv_.wait_for(g, std::chrono::milliseconds(300), [&] { return updated_; });
}

bool Replay::waitForUpdate(obs_data_t *settings) {
    // Fontes com vídeo recebem o update no video_tick seguinte (obs-source.c: defer_update_count) e o sinal "update"
    // chega nessa altura. O sinal pode ser de um update que já estava a correr quando as definições foram aplicadas,
    // por isso espera-se por um SEGUNDO update (sem definições novas), que corre garantidamente depois do apply.
    { std::lock_guard g(updM_); updated_ = false; }
    obs_source_update(replay_, settings);
    if (!waitForSignal()) return false;
    { std::lock_guard g(updM_); updated_ = false; }
    obs_source_update(replay_, nullptr);
    return waitForSignal();
}

bool Replay::triggerHotkey(const char *name) {
    auto it = hotkeys_.find(name);
    if (it == hotkeys_.end()) { fprintf(stderr, "replay: hotkey %s não encontrada\n", name); return false; }
    obs_hotkey_trigger_routed_callback(it->second, true); // síncrono, no thread chamador
    obs_hotkey_trigger_routed_callback(it->second, false);
    return true;
}

size_t Replay::bufferedFrames(obs_source_t *filter) {
    const char *id = filter ? obs_source_get_unversioned_id(filter) : nullptr;
    if (!id || (strcmp(id, REPLAY_FILTER_ID) != 0 && strcmp(id, REPLAY_FILTER_ASYNC_ID) != 0)) return 0;
    auto *f = static_cast<struct replay_filter *>(obs_obj_get_data(filter));
    if (!f) return 0;
    pthread_mutex_lock(&f->mutex);
    size_t n = f->video_frames.size / sizeof(struct obs_source_frame *);
    pthread_mutex_unlock(&f->mutex);
    return n;
}

void Replay::attachReplayInput(const std::string &inputId) {
    std::lock_guard l(m_);
    replayId_ = inputId;
    replay_ = sw_.sourceRef(inputId);
    hotkeys_.clear();
    loaded_ = false; paused_ = false; linkedAngle_.clear(); clipAngle_.clear();
    if (!replay_) { fprintf(stderr, "replay: fonte %s não existe no Switcher\n", inputId.c_str()); return; }
    signal_handler_connect(obs_source_get_signal_handler(replay_), "update", onSourceUpdate, this);
    struct Find { obs_source_t *src; std::map<std::string, obs_hotkey_id> *out; } f{replay_, &hotkeys_};
    obs_enum_hotkeys([](void *d, obs_hotkey_id id, obs_hotkey_t *key) {
        auto *fd = static_cast<Find *>(d);
        // Hotkeys de fonte guardam uma referência fraca (obs_hotkey_register_source → obs_source_get_weak_source), não o obs_source_t*.
        if (obs_hotkey_get_registerer_type(key) == OBS_HOTKEY_REGISTERER_SOURCE &&
            obs_weak_source_references_source(static_cast<obs_weak_source_t *>(obs_hotkey_get_registerer(key)), fd->src))
            (*fd->out)[obs_hotkey_get_name(key)] = id;
        return true;
    }, &f);
    // O plugin só lê as definições no update/load: aplica a duração e a velocidade do estado (update diferido para o tick seguinte).
    double speed = store_.state()["replay"].value("speedPercent", 100.0);
    obs_data_t *d = obs_data_create();
    obs_data_set_int(d, "duration", bufferSeconds_ * 1000);
    obs_data_set_double(d, "speed_percent", speed);
    obs_source_update(replay_, d);
    obs_data_release(d);
    syncState();
}

double Replay::estimateMemoryMB(int bufferSeconds, const std::vector<std::string> &angles) {
    json s = store_.state();
    double fps = s["project"]["raster"].value("fps", 50.0);
    uint32_t rw = s["project"]["raster"].value("width", 1920), rh = s["project"]["raster"].value("height", 1080);
    if (fps <= 0) fps = 50;
    if (!rw || !rh) { rw = 1920; rh = 1080; }
    double total = 0, maxRate = 0;
    for (auto &a : angles) {
        obs_source_t *src = sw_.sourceRef(a);
        if (!src) continue;
        bool async = (obs_source_get_output_flags(src) & OBS_SOURCE_ASYNC) != 0;
        uint32_t w = obs_source_get_base_width(src), h = obs_source_get_base_height(src);
        if (!w || !h) { w = rw; h = rh; } // ainda sem imagem: assume o raster
        std::string kind = s["inputs"].contains(a) ? s["inputs"][a].value("kind", "") : "";
        // replay_filter (síncrono) guarda BGRA (4 B/px); replay_filter_async guarda o formato nativo: NV12/I420 (1,5 B/px) no
        // ffmpeg com VideoToolbox e no AVCapture, BGRA (4 B/px) no NDI.
        double bpp = !async ? 4.0 : kind == "ndi" ? 4.0 : 1.5;
        double rate = (double)w * h * bpp * fps; // bytes por segundo (a taxa real das fontes async é a da fonte; fps do raster é o majorante)
        total += rate * bufferSeconds;
        if (rate > maxRate) maxRate = rate;
    }
    total += 2 * maxRate * bufferSeconds; // a replay_source guarda até 2 lances (replays=2), cada um com `bufferSeconds` de frames
    return total / 1e6;
}

void Replay::syncState(const std::function<void(json &)> &extra) {
    double mb = estimateMemoryMB(bufferSeconds_, order_);
    store_.mutate([&](json &s) {
        json &r = s["replay"];
        r["bufferSeconds"] = bufferSeconds_;
        r["angles"] = order_;
        r["inputId"] = replayId_.empty() ? json() : json(replayId_);
        r["loadedAngle"] = loaded_ && !clipAngle_.empty() ? json(clipAngle_) : json();
        r["paused"] = paused_;
        r["memoryMB"] = (int)(mb + 0.5);
        r["status"] = !available_ ? "unavailable" : loaded_ ? "loaded" : order_.empty() ? "idle" : "buffering";
        if (extra) extra(r);
    });
}

bool Replay::armAngle(const std::string &id, int durationMs, std::string &message) {
    obs_source_t *src = sw_.sourceRef(id);
    if (!src) { message = "fonte não encontrada: " + id; return false; }
    uint32_t flags = obs_source_get_output_flags(src);
    if (!(flags & OBS_SOURCE_VIDEO)) { message = "a fonte não tem vídeo: " + id; return false; }
    Angle a;
    a.async = (flags & OBS_SOURCE_ASYNC) != 0;
    a.hasAudio = (flags & OBS_SOURCE_AUDIO) != 0;
    obs_data_t *d = obs_data_create();
    obs_data_set_int(d, "duration", durationMs);
    obs_data_set_bool(d, "internal_frames", false); // lê a async_cache da libobs por offset fixo: nunca
    obs_data_set_bool(d, "sound_trigger", false);
    obs_data_set_double(d, "threshold", -60);
    // Nome = nome obs do ângulo (= inputId): o replay_filter_check do plugin exige uma fonte pública com o nome do filtro.
    a.filter = obs_source_create_private(a.async ? REPLAY_FILTER_ASYNC_ID : REPLAY_FILTER_ID, id.c_str(), d);
    obs_data_release(d);
    if (!a.filter) { message = "não foi possível criar o filtro de replay"; return false; }
    obs_source_filter_add(src, a.filter);
    if (obs_filter_get_parent(a.filter) != src) { // filtro incompatível com as capacidades da fonte (filter_compatible)
        obs_source_release(a.filter);
        message = "a fonte não aceita o filtro de replay: " + id;
        return false;
    }
    angles_[id] = a;
    fprintf(stderr, "replay: ângulo %s armado (%s, %d ms)\n", id.c_str(), a.async ? "async" : "sync", durationMs);
    return true;
}

void Replay::unlinkAngle() {
    if (linkedAngle_.empty()) return;
    auto it = angles_.find(linkedAngle_);
    if (it != angles_.end()) obs_source_set_name(it->second.filter, linkedAngle_.c_str());
    linkedAngle_.clear();
    if (!replay_) return;
    // Sem isto o update diferido seguinte da replay_source (duração, velocidade, …) voltava a procurar `source`, não encontrava
    // filtro com o seu nome e criava um buffer próprio nessa fonte, fora de replay.angles e do orçamento de memória.
    obs_data_t *d = obs_data_create();
    obs_data_set_string(d, "source", "");
    obs_data_set_string(d, "source_audio", "");
    if (!waitForUpdate(d)) fprintf(stderr, "replay: a replay_source não confirmou o esquecimento da fonte em 600 ms\n");
    obs_data_release(d);
}

void Replay::disarmAngle(const std::string &id) {
    auto it = angles_.find(id);
    if (it == angles_.end()) return;
    if (linkedAngle_ == id) unlinkAngle(); // antes de remover o filtro, senão o plugin recria-o órfão
    // A destruição é diferida pela libobs (destruction_task_thread); o filtro síncrono liberta as texturas com o contexto
    // gráfico próprio (patch em third_party/obs-replay-source/replay-filter.c).
    if (obs_source_t *parent = obs_filter_get_parent(it->second.filter)) obs_source_filter_remove(parent, it->second.filter);
    obs_source_release(it->second.filter);
    angles_.erase(it);
    order_.erase(std::remove(order_.begin(), order_.end(), id), order_.end());
    if (clipAngle_ == id) clipAngle_.clear(); // o lance continua carregado, mas o ângulo já não está armado
}

std::string Replay::setup(int bufferSeconds, const std::vector<std::string> &angles, std::string &message) {
    std::lock_guard l(m_);
    if (!available_) { message = "plugin Replay Source não carregado"; return "CAPABILITY_MISSING"; }
    if (!replay_ && !angles.empty()) { message = "fonte Replay inexistente"; return "INVALID_PARAMS"; }
    bufferSeconds_ = bufferSeconds;
    int ms = bufferSeconds * 1000;
    std::vector<std::string> gone;
    for (auto &[id, a] : angles_) if (std::find(angles.begin(), angles.end(), id) == angles.end()) gone.push_back(id);
    for (auto &id : gone) disarmAngle(id);
    for (auto &id : angles) {
        auto it = angles_.find(id);
        if (it != angles_.end()) {
            obs_data_t *d = obs_data_create();
            obs_data_set_int(d, "duration", ms);
            obs_source_update(it->second.filter, d); // encurtar descarta o buffer; alongar mantém-no
            obs_data_release(d);
        } else if (!armAngle(id, ms, message)) {
            order_ = angles; order_.erase(std::remove_if(order_.begin(), order_.end(), [&](const std::string &x) { return !angles_.count(x); }), order_.end());
            syncState();
            return "DEVICE_UNAVAILABLE";
        }
    }
    order_ = angles;
    if (replay_) { // a replay_source sincroniza `duration` para o filtro ligado em cada update
        obs_data_t *d = obs_data_create();
        obs_data_set_int(d, "duration", ms);
        obs_source_update(replay_, d);
        obs_data_release(d);
    }
    syncState();
    return "";
}

std::string Replay::capture(const std::string &angleId, std::string &message) {
    std::lock_guard l(m_);
    if (!available_) { message = "plugin Replay Source não carregado"; return "CAPABILITY_MISSING"; }
    if (!replay_) { message = "fonte Replay inexistente (replay.setup primeiro)"; return "INVALID_PARAMS"; }
    auto it = angles_.find(angleId);
    if (it == angles_.end()) { message = "ângulo não armado: " + angleId; return "INVALID_PARAMS"; }
    Angle &a = it->second;
    size_t before = bufferedFrames(a.filter);
    if (before < 5) { message = "o buffer do ângulo ainda está a encher (" + std::to_string(before) + " frames)"; return "NOT_RUNNING"; }
    // Só o filtro do ângulo a capturar fica com o nome da replay_source (o plugin procura-o por esse nome e removê-lo-ia da
    // fonte anterior ao mudar `source`); o anterior volta ao nome do seu ângulo e continua a encher.
    if (linkedAngle_ != angleId) {
        if (!linkedAngle_.empty()) {
            auto prev = angles_.find(linkedAngle_);
            if (prev != angles_.end()) obs_source_set_name(prev->second.filter, linkedAngle_.c_str());
        }
        obs_source_set_name(a.filter, replayId_.c_str());
        linkedAngle_ = angleId;
    }
    obs_data_t *d = obs_data_create();
    obs_data_set_string(d, "source", angleId.c_str());
    obs_data_set_string(d, "source_audio", a.hasAudio ? angleId.c_str() : "");
    bool ok = waitForUpdate(d); // o Load usa o `source` já aplicado pelo update diferido
    obs_data_release(d);
    if (!ok) { message = "a replay_source não confirmou a ligação ao ângulo (motor parado?)"; syncState(); return "NOT_RUNNING"; }
    triggerHotkey("ReplaySource.Replay"); // move os frames do buffer para um lance novo (replays=2: anexa sem seleccionar)
    size_t after = bufferedFrames(a.filter);
    if (after >= before) { // o Load não esvaziou o buffer: o plugin não encontrou o filtro (nome/ligação)
        message = "o plugin não carregou o lance (" + std::to_string(before) + " → " + std::to_string(after) + " frames)";
        syncState();
        return "NOT_RUNNING";
    }
    triggerHotkey("ReplaySource.Last");   // selecciona o lance acabado de carregar e começa a tocá-lo
    loaded_ = true; paused_ = false; clipAngle_ = angleId;
    fprintf(stderr, "replay: lance do ângulo %s carregado (%zu frames)\n", angleId.c_str(), before - after);
    syncState();
    return "";
}

void Replay::setSpeed(double percent) {
    std::lock_guard l(m_);
    double old = store_.state()["replay"].value("speedPercent", 100.0);
    if (replay_) {
        // speed_percent nas settings não compensa a posição (congela ao descer, salta ao subir): reposiciona o relógio
        // do lance para o mesmo frame (update primeiro, set_time depois; ambos consumidos no tick seguinte).
        int64_t t = loaded_ ? obs_source_media_get_time(replay_) : 0;
        obs_data_t *d = obs_data_create();
        obs_data_set_double(d, "speed_percent", percent);
        obs_source_update(replay_, d);
        obs_data_release(d);
        if (loaded_ && old > 0) obs_source_media_set_time(replay_, (int64_t)(t * old / percent));
    }
    syncState([&](json &r) { r["speedPercent"] = percent; });
}

void Replay::pause(bool on) {
    std::lock_guard l(m_);
    if (replay_) {
        // play_pause(true) no plugin é um toggle: só se envia na transição a tocar → em pausa; play_pause(false) é um play
        // determinístico (recomeça se tinha terminado).
        if (on) { if (!paused_ && obs_source_media_get_state(replay_) == OBS_MEDIA_STATE_PLAYING) obs_source_media_play_pause(replay_, true); }
        else obs_source_media_play_pause(replay_, false);
    }
    paused_ = on;
    syncState();
}

void Replay::restart() {
    std::lock_guard l(m_);
    if (replay_) obs_source_media_restart(replay_);
    paused_ = false;
    syncState();
}

void Replay::next() {
    std::lock_guard l(m_);
    if (replay_) obs_source_media_next(replay_);
    paused_ = false;
    syncState();
}

void Replay::previous() {
    std::lock_guard l(m_);
    if (replay_) obs_source_media_previous(replay_);
    paused_ = false;
    syncState();
}

void Replay::clear() {
    std::lock_guard l(m_);
    if (replay_) triggerHotkey("ReplaySource.Clear"); // liberta os lances guardados; os buffers dos ângulos continuam a encher
    unlinkAngle(); // a replay_source esquece o ângulo (o filtro volta ao nome dele)
    loaded_ = false; paused_ = false; clipAngle_.clear();
    syncState();
}

void Replay::prepareOnAir() {
    std::lock_guard l(m_);
    if (replay_ && loaded_) obs_source_media_restart(replay_);
    paused_ = false;
}

void Replay::detachReplayInput() {
    if (replay_) signal_handler_disconnect(obs_source_get_signal_handler(replay_), "update", onSourceUpdate, this);
    replay_ = nullptr; // a fonte vai ser destruída: não se espera por updates dela
    linkedAngle_.clear();
    std::vector<std::string> ids;
    for (auto &[id, a] : angles_) ids.push_back(id);
    for (auto &id : ids) disarmAngle(id); // sem fonte Replay os buffers só gastariam RAM
    order_.clear();
    hotkeys_.clear();
    replayId_.clear();
    loaded_ = false; paused_ = false; clipAngle_.clear();
    syncState([&](json &r) { r["onAir"] = false; r["liveInput"] = nullptr; });
}

void Replay::onInputRemoved(const std::string &inputId) {
    std::lock_guard l(m_);
    if (!inputId.empty() && inputId == replayId_) { detachReplayInput(); return; }
    if (!angles_.count(inputId)) return;
    disarmAngle(inputId); // o lance já carregado continua na replay_source (os frames foram movidos)
    if (clipAngle_ == inputId) clipAngle_.clear();
    syncState();
}
