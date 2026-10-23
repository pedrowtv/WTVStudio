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
    obs_data_t *vs = obs_data_create();
    obs_data_set_int(vs, "bitrate", 6000); obs_data_set_string(vs, "rate_control", "CBR");
    obs_data_set_int(vs, "keyint_sec", 2); obs_data_set_string(vs, "profile", "high"); obs_data_set_bool(vs, "bframes", false);
    video_ = obs_video_encoder_create(rt_.videoEncoderId().c_str(), "wtv-program-h264", vs, nullptr);
    obs_data_release(vs);
    obs_data_t *as = obs_data_create();
    obs_data_set_int(as, "bitrate", 160);
    audio_ = obs_audio_encoder_create("CoreAudio_AAC", "wtv-program-aac", as, 0, nullptr);
    if (!audio_) audio_ = obs_audio_encoder_create("ffmpeg_aac", "wtv-program-aac", as, 0, nullptr);
    obs_data_release(as);
    if (!video_ || !audio_) return false;
    obs_encoder_set_video(video_, obs_get_video());
    obs_encoder_set_audio(audio_, obs_get_audio());
    return true;
}

bool Outputs::anyActive() {
    if (rec_ && obs_output_active(rec_)) return true;
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
    if (kind != "rtmp" && kind != "srt") { error = "CAPABILITY_MISSING"; return ""; }
    std::string url = c.value("url", "");
    if (kind == "srt" && url.rfind("srt://", 0) != 0) { error = "INVALID_PARAMS"; return ""; }
    std::string id = newId();
    {
        std::lock_guard l(m_);
        Entry e; e.kind = kind; e.url = url; e.key = c.value("streamKey", ""); e.latencyMs = c.value("latencyMs", 120);
        outputs_[id] = e;
    }
    store_.mutate([&](json &s) {
        json cfg = {{"url", url}};
        if (kind == "rtmp") cfg["hasStreamKey"] = !c.value("streamKey", "").empty();
        if (kind == "srt") cfg["latencyMs"] = c.value("latencyMs", 120);
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
    if (!ensureEncoders()) { error = "ENCODER_BUDGET"; return false; }
    if (e.output) { obs_output_release(e.output); e.output = nullptr; }
    if (e.service) { obs_service_release(e.service); e.service = nullptr; }
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
