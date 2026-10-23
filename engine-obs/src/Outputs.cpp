#include "Outputs.h"
#include <chrono>
#include <ctime>
#include <random>
#include <thread>

static std::string newId() {
    static std::mt19937_64 rng{std::random_device{}()};
    std::string s = "out_"; for (int i = 0; i < 6; i++) s += "0123456789abcdef"[rng() % 16]; return s;
}
static std::string nowIso() { char b[32]; time_t t = time(nullptr); strftime(b, sizeof b, "%Y-%m-%dT%H:%M:%SZ", gmtime(&t)); return b; }

bool Outputs::ensureEncoders() {
    if (video_) return true;
    json enc = store_.state()["project"].value("encoding", json::object());
    obs_data_t *vs = obs_data_create();
    obs_data_set_int(vs, "bitrate", enc.value("videoBitrateKbps", 6000)); obs_data_set_string(vs, "rate_control", enc.value("rateControl", "CBR").c_str());
    obs_data_set_int(vs, "keyint_sec", enc.value("keyintSec", 2)); obs_data_set_string(vs, "profile", enc.value("profile", "high").c_str()); obs_data_set_bool(vs, "bframes", false);
    video_ = obs_video_encoder_create(rt_.videoEncoderId().c_str(), "wtv-program-h264", vs, nullptr);
    obs_data_release(vs);
    obs_data_t *as = obs_data_create();
    obs_data_set_int(as, "bitrate", enc.value("audioBitrateKbps", 160));
    audio_ = obs_audio_encoder_create("CoreAudio_AAC", "wtv-program-aac", as, mixerIdx_, nullptr);
    if (!audio_) audio_ = obs_audio_encoder_create("ffmpeg_aac", "wtv-program-aac", as, mixerIdx_, nullptr);
    obs_data_release(as);
    if (!video_ || !audio_) return false;
    obs_encoder_set_video(video_, obs_get_video());
    obs_encoder_set_audio(audio_, obs_get_audio());
    return true;
}

bool Outputs::anyActive() {
    if (rec_ && obs_output_active(rec_)) return true;
    if (!iso_.empty()) return true;
    for (auto &[id, e] : outputs_) if (e.output && obs_output_active(e.output)) return true;
    return false;
}

void Outputs::releaseEncodersIfIdle() {
    if (anyActive() || !video_) return;
    obs_encoder_release(video_); obs_encoder_release(audio_); video_ = audio_ = nullptr;
}

void Outputs::setStatus(const std::string &id, const std::string &status, const std::string &code) {
    store_.mutate([&](json &s) {
        if (!s["outputs"].contains(id)) return;
        s["outputs"][id]["status"] = status;
        if (code.empty()) s["outputs"][id].erase("statusCode"); else s["outputs"][id]["statusCode"] = code;
        if (status == "live" && !s["outputs"][id].contains("startedAt")) s["outputs"][id]["startedAt"] = nowIso();
        if (status == "stopped" || status == "error") s["outputs"][id].erase("startedAt");
    });
}

void Outputs::onStart(void *d, calldata_t *) { auto *c = (SignalCtx *)d; c->self->setStatus(c->id, "live"); }
void Outputs::onReconnect(void *d, calldata_t *) { auto *c = (SignalCtx *)d; c->self->setStatus(c->id, "reconnecting"); }
void Outputs::onReconnectOk(void *d, calldata_t *) { auto *c = (SignalCtx *)d; c->self->setStatus(c->id, "live"); }
void Outputs::onStop(void *d, calldata_t *cd) {
    auto *c = (SignalCtx *)d;
    long long code = calldata_int(cd, "code");
    const char *err = calldata_string(cd, "last_error");
    c->self->setStatus(c->id, code == 0 ? "stopped" : "error", code == 0 ? "" : (err && *err ? err : "code " + std::to_string(code)));
    std::thread([self = c->self] { std::lock_guard l(self->m_); self->releaseEncodersIfIdle(); }).detach();
}

std::string Outputs::add(const std::string &kind, const std::string &name, const json &c, std::string &error) {
    if (kind != "rtmp" && kind != "srt" && kind != "ndi") { error = "CAPABILITY_MISSING"; return ""; }
    if (kind == "ndi" && !ndiAvailable_) { error = "CAPABILITY_MISSING"; return ""; }
    std::string url = c.value("url", "");
    if (kind == "srt" && url.rfind("srt://", 0) != 0) { error = "INVALID_PARAMS"; return ""; }
    std::string id = newId();
    {
        std::lock_guard l(m_);
        Entry e; e.kind = kind; e.url = url; e.key = c.value("streamKey", ""); e.latencyMs = c.value("latencyMs", 120);
        e.ndiName = c.value("ndiName", "WTV Studio");
        outputs_[id] = e;
    }
    store_.mutate([&](json &s) {
        json cfg = {{"url", url}};
        if (kind == "rtmp") cfg["hasStreamKey"] = !c.value("streamKey", "").empty();
        if (kind == "srt") cfg["latencyMs"] = c.value("latencyMs", 120);
        if (kind == "ndi") cfg["ndiName"] = c.value("ndiName", "WTV Studio");
        s["outputs"][id] = {{"id", id}, {"kind", kind}, {"name", name.empty() ? kind : name}, {"status", "stopped"},
                            {"profileId", "default"}, {"config", cfg}, {"autoRestart", false}};
    });
    return id;
}

bool Outputs::update(const std::string &id, const json &p) {
    std::lock_guard l(m_);
    auto it = outputs_.find(id);
    if (it == outputs_.end()) return false;
    if (p.contains("config")) {
        auto &c = p["config"];
        if (c.contains("url")) it->second.url = c["url"];
        if (c.contains("streamKey") && !c["streamKey"].get<std::string>().empty()) it->second.key = c["streamKey"];
        if (c.contains("latencyMs")) it->second.latencyMs = c["latencyMs"];
        if (c.contains("ndiName")) it->second.ndiName = c["ndiName"];
    }
    store_.mutate([&](json &s) {
        json &o = s["outputs"][id];
        if (p.contains("name")) o["name"] = p["name"];
        if (p.contains("autoRestart")) o["autoRestart"] = p["autoRestart"];
        if (p.contains("config")) {
            auto &c = p["config"];
            if (c.contains("url")) o["config"]["url"] = c["url"];
            if (c.contains("streamKey")) o["config"]["hasStreamKey"] = !it->second.key.empty();
            if (c.contains("latencyMs")) o["config"]["latencyMs"] = c["latencyMs"];
            if (c.contains("ndiName")) o["config"]["ndiName"] = c["ndiName"];
        }
    });
    return true;
}

bool Outputs::remove(const std::string &id, std::string &error) {
    std::lock_guard l(m_);
    auto it = outputs_.find(id);
    if (it == outputs_.end()) { error = "OUTPUT_NOT_FOUND"; return false; }
    if (it->second.output && obs_output_active(it->second.output)) { error = "ALREADY_RUNNING"; return false; }
    if (it->second.output) obs_output_release(it->second.output);
    if (it->second.service) obs_service_release(it->second.service);
    if (ctx_.count(id)) { delete ctx_[id]; ctx_.erase(id); }
    outputs_.erase(it);
    store_.mutate([&](json &s) { s["outputs"].erase(id); });
    return true;
}

bool Outputs::start(const std::string &id, std::string &error) {
    std::lock_guard l(m_);
    auto it = outputs_.find(id);
    if (it == outputs_.end()) { error = "OUTPUT_NOT_FOUND"; return false; }
    Entry &e = it->second;
    if (e.output && obs_output_active(e.output)) { error = "ALREADY_RUNNING"; return false; }
    if (e.output) { obs_output_release(e.output); e.output = nullptr; }
    if (e.service) { obs_service_release(e.service); e.service = nullptr; }
    if (e.kind == "ndi") {
        obs_data_t *os = obs_data_create();
        obs_data_set_string(os, "ndi_name", e.ndiName.c_str());
        e.output = obs_output_create("wtv_ndi_output", id.c_str(), os, nullptr);
        obs_data_release(os);
        if (!e.output) { error = "DEVICE_UNAVAILABLE"; return false; }
        obs_output_set_mixer(e.output, (size_t)ndiMixerIdx_);
        if (!ctx_.count(id)) ctx_[id] = new SignalCtx{this, id};
        signal_handler_t *sh = obs_output_get_signal_handler(e.output);
        signal_handler_connect(sh, "start", onStart, ctx_[id]);
        signal_handler_connect(sh, "stop", onStop, ctx_[id]);
        setStatus(id, "starting");
        if (!obs_output_start(e.output)) { const char *le = obs_output_get_last_error(e.output); setStatus(id, "error", le ? le : "falha ao iniciar"); error = "DEVICE_UNAVAILABLE"; return false; }
        return true;
    }
    if (!ensureEncoders()) { error = "ENCODER_BUDGET"; return false; }
    std::string server = e.url;
    if (e.kind == "srt" && server.find("latency=") == std::string::npos)
        server += (server.find('?') == std::string::npos ? "?" : "&") + std::string("latency=") + std::to_string(e.latencyMs * 1000);
    obs_data_t *ss = obs_data_create();
    obs_data_set_string(ss, "server", server.c_str());
    obs_data_set_string(ss, "key", e.key.c_str());
    e.service = obs_service_create_private("rtmp_custom", id.c_str(), ss);
    obs_data_release(ss);
    e.output = obs_output_create(e.kind == "srt" ? "ffmpeg_mpegts_muxer" : "rtmp_output", id.c_str(), nullptr, nullptr);
    if (!e.output || !e.service) { error = "DEVICE_UNAVAILABLE"; return false; }
    obs_output_set_video_encoder(e.output, video_);
    obs_output_set_audio_encoder(e.output, audio_, 0);
    obs_output_set_service(e.output, e.service);
    obs_output_set_reconnect_settings(e.output, 20, 2);
    if (!ctx_.count(id)) ctx_[id] = new SignalCtx{this, id};
    signal_handler_t *sh = obs_output_get_signal_handler(e.output);
    signal_handler_connect(sh, "start", onStart, ctx_[id]);
    signal_handler_connect(sh, "stop", onStop, ctx_[id]);
    signal_handler_connect(sh, "reconnect", onReconnect, ctx_[id]);
    signal_handler_connect(sh, "reconnect_success", onReconnectOk, ctx_[id]);
    setStatus(id, "starting");
    if (!obs_output_start(e.output)) {
        const char *le = obs_output_get_last_error(e.output);
        setStatus(id, "error", le ? le : "falha ao iniciar");
        error = "DEVICE_UNAVAILABLE";
        releaseEncodersIfIdle();
        return false;
    }
    return true;
}

bool Outputs::stop(const std::string &id) {
    std::lock_guard l(m_);
    auto it = outputs_.find(id);
    if (it == outputs_.end() || !it->second.output) return false;
    obs_output_stop(it->second.output);
    return true;
}

bool Outputs::startRecording(std::string &error) {
    std::lock_guard l(m_);
    if (rec_) { error = "já a gravar"; return false; }
    if (!ensureEncoders()) { error = "codificadores indisponíveis"; return false; }
    json s = store_.state();
    std::string folder = s["recording"]["folder"].is_string() ? s["recording"]["folder"].get<std::string>() : std::string(getenv("HOME")) + "/Movies/WTV Studio";
    std::string container = s["recording"].value("container", "mp4");
    system(("mkdir -p \"" + folder + "\"").c_str());
    char name[64]; time_t t = time(nullptr); strftime(name, sizeof name, "WTV %Y-%m-%d %H-%M-%S", localtime(&t));
    std::string path = folder + "/" + name + "." + container;
    obs_data_t *os = obs_data_create();
    obs_data_set_string(os, "path", path.c_str());
    rec_ = obs_output_create("ffmpeg_muxer", "wtv-rec", os, nullptr);
    obs_data_release(os);
    obs_output_set_video_encoder(rec_, video_);
    obs_output_set_audio_encoder(rec_, audio_, 0);
    if (!obs_output_start(rec_)) {
        const char *le = obs_output_get_last_error(rec_);
        error = le ? le : "falha ao iniciar";
        obs_output_release(rec_); rec_ = nullptr; releaseEncodersIfIdle();
        return false;
    }
    store_.mutate([&](json &st) { st["recording"]["status"] = "recording"; st["recording"]["file"] = path; st["recording"]["startedAt"] = nowIso(); });
    return true;
}

void Outputs::stopRecording() {
    std::lock_guard l(m_);
    if (!rec_) return;
    store_.mutate([](json &st) { st["recording"]["status"] = "stopping"; });
    obs_output_stop(rec_);
    for (int i = 0; i < 100 && obs_output_active(rec_); i++) std::this_thread::sleep_for(std::chrono::milliseconds(50));
    obs_output_release(rec_); rec_ = nullptr;
    releaseEncodersIfIdle();
    store_.mutate([](json &st) { st["recording"]["status"] = "idle"; st["recording"].erase("file"); st["recording"].erase("startedAt"); });
}

void Outputs::shutdown() {
    isoStopAll();
    stopRecording();
    std::lock_guard l(m_);
    for (auto &[id, e] : outputs_) {
        if (e.output) { if (obs_output_active(e.output)) obs_output_force_stop(e.output); obs_output_release(e.output); }
        if (e.service) obs_service_release(e.service);
    }
    outputs_.clear();
    for (auto &[id, c] : ctx_) delete c;
    ctx_.clear();
    if (video_) { obs_encoder_release(video_); obs_encoder_release(audio_); video_ = audio_ = nullptr; }
}

bool Outputs::applyEncodingChange(std::string &error) {
    std::lock_guard l(m_);
    if (anyActive()) { error = "ALREADY_RUNNING"; return false; }
    releaseEncodersIfIdle();
    return true;
}

void Outputs::setNdiBus(int idx) { std::lock_guard l(m_); ndiMixerIdx_ = idx; for (auto &[id, e] : outputs_) if (e.kind == "ndi" && e.output) obs_output_set_mixer(e.output, (size_t)idx); }

bool Outputs::setStreamBus(int idx, std::string &error) {
    std::lock_guard l(m_);
    if (anyActive()) { error = "ALREADY_RUNNING"; return false; }
    mixerIdx_ = idx;
    releaseEncodersIfIdle();
    return true;
}

// ---------------- MultiCorder (ISO) ----------------
static std::string isoFolder(StateStore &store) {
    json s = store.state();
    std::string folder = s["recording"]["folder"].is_string() ? s["recording"]["folder"].get<std::string>() : std::string(getenv("HOME")) + "/Movies/WTV Studio";
    folder += "/iso";
    system(("mkdir -p \"" + folder + "\"").c_str());
    return folder;
}

void Outputs::onIsoStop(void *d, calldata_t *cd) {
    auto *c = (SignalCtx *)d;
    long long code = calldata_int(cd, "code");
    c->self->store_.mutate([&](json &s) { if (s["recording"].contains("iso") && s["recording"]["iso"].contains(c->id)) { s["recording"]["iso"][c->id]["status"] = code == 0 ? "idle" : "error"; } });
}

bool Outputs::isoStart(const std::string &id, obs_source_t *source, const std::string &name, std::string &error) {
    std::lock_guard l(m_);
    if (iso_.count(id)) { error = "ALREADY_RUNNING"; return false; }
    if (!source) { error = "INPUT_NOT_FOUND"; return false; }
    int track = -1;
    for (int t = 3; t <= 5; t++) { bool used = false; for (auto &[k, v] : iso_) if (v.track == t) used = true; if (!used) { track = t; break; } }
    if (track < 0) { error = "ENCODER_BUDGET"; return false; } // 3 tracks livres (4..6) → máximo 3 ISO com áudio em simultâneo
    obs_video_info ovi{}; obs_get_video_info(&ovi);
    Iso iso; iso.track = track;
    iso.scene = obs_scene_create_private(("iso-" + id).c_str());
    obs_sceneitem_t *item = obs_scene_add(iso.scene, source);
    vec2 pos{0, 0}, bounds{(float)ovi.base_width, (float)ovi.base_height};
    obs_sceneitem_set_bounds_type(item, OBS_BOUNDS_SCALE_INNER);
    obs_sceneitem_set_bounds_alignment(item, OBS_ALIGN_CENTER);
    obs_sceneitem_set_pos(item, &pos); obs_sceneitem_set_bounds(item, &bounds);
    iso.view = obs_view_create();
    obs_view_set_source(iso.view, 0, obs_scene_get_source(iso.scene));
    iso.video = obs_view_add2(iso.view, &ovi); // mesmo raster e fps do Program
    if (!iso.video) { obs_view_destroy(iso.view); obs_scene_release(iso.scene); error = "DEVICE_UNAVAILABLE"; return false; }
    json enc = store_.state()["project"].value("encoding", json::object());
    obs_data_t *vs = obs_data_create();
    obs_data_set_int(vs, "bitrate", enc.value("videoBitrateKbps", 6000)); obs_data_set_string(vs, "rate_control", "CBR");
    obs_data_set_int(vs, "keyint_sec", 2); obs_data_set_string(vs, "profile", "high"); obs_data_set_bool(vs, "bframes", false);
    iso.venc = obs_video_encoder_create(rt_.videoEncoderId().c_str(), ("iso-h264-" + id).c_str(), vs, nullptr);
    obs_data_release(vs);
    obs_data_t *as = obs_data_create(); obs_data_set_int(as, "bitrate", enc.value("audioBitrateKbps", 160));
    iso.aenc = obs_audio_encoder_create("CoreAudio_AAC", ("iso-aac-" + id).c_str(), as, (size_t)track, nullptr);
    if (!iso.aenc) iso.aenc = obs_audio_encoder_create("ffmpeg_aac", ("iso-aac-" + id).c_str(), as, (size_t)track, nullptr);
    obs_data_release(as);
    obs_encoder_set_video(iso.venc, iso.video);
    obs_encoder_set_audio(iso.aenc, obs_get_audio());
    if (audioEngine_) audioEngine_->setIsoTrack(id, track);
    std::string safe = name; for (auto &c : safe) if (c == '/' || c == ':') c = '-';
    char ts[64]; time_t t = time(nullptr); strftime(ts, sizeof ts, "%Y-%m-%d %H-%M-%S", localtime(&t));
    iso.file = isoFolder(store_) + "/" + safe + " " + ts + ".mp4";
    obs_data_t *os = obs_data_create(); obs_data_set_string(os, "path", iso.file.c_str());
    iso.out = obs_output_create("ffmpeg_muxer", ("iso-" + id).c_str(), os, nullptr);
    obs_data_release(os);
    obs_output_set_media(iso.out, iso.video, obs_get_audio());
    obs_output_set_video_encoder(iso.out, iso.venc);
    obs_output_set_audio_encoder(iso.out, iso.aenc, 0);
    std::string key = "iso:" + id;
    if (!ctx_.count(key)) ctx_[key] = new SignalCtx{this, id};
    signal_handler_connect(obs_output_get_signal_handler(iso.out), "stop", onIsoStop, ctx_[key]);
    iso_[id] = iso;
    if (!obs_output_start(iso.out)) {
        const char *le = obs_output_get_last_error(iso.out);
        error = le ? le : "falha ao iniciar";
        isoRelease(id);
        return false;
    }
    std::string file = iso.file;
    store_.mutate([&](json &s) { s["recording"]["iso"][id] = {{"status", "recording"}, {"file", file}, {"startedAt", nowIso()}, {"track", track + 1}}; });
    return true;
}

void Outputs::isoRelease(const std::string &id) {
    auto it = iso_.find(id);
    if (it == iso_.end()) return;
    Iso &iso = it->second;
    if (iso.out) obs_output_release(iso.out);
    if (iso.venc) obs_encoder_release(iso.venc);
    if (iso.aenc) obs_encoder_release(iso.aenc);
    if (iso.view) { obs_view_set_source(iso.view, 0, nullptr); obs_view_remove(iso.view); obs_view_destroy(iso.view); }
    if (iso.scene) obs_scene_release(iso.scene);
    if (audioEngine_) audioEngine_->setIsoTrack(id, -1);
    iso_.erase(it);
}

bool Outputs::isoStop(const std::string &id) {
    std::lock_guard l(m_);
    auto it = iso_.find(id);
    if (it == iso_.end()) return false;
    store_.mutate([&](json &s) { if (s["recording"].contains("iso") && s["recording"]["iso"].contains(id)) s["recording"]["iso"][id]["status"] = "stopping"; });
    obs_output_stop(it->second.out);
    for (int i = 0; i < 100 && obs_output_active(it->second.out); i++) std::this_thread::sleep_for(std::chrono::milliseconds(50));
    isoRelease(id);
    store_.mutate([&](json &s) { if (s["recording"].contains("iso")) s["recording"]["iso"].erase(id); });
    return true;
}

void Outputs::isoStopAll() {
    std::vector<std::string> ids;
    { std::lock_guard l(m_); for (auto &[id, v] : iso_) ids.push_back(id); }
    for (auto &id : ids) isoStop(id);
}
