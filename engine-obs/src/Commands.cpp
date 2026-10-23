#include "Commands.h"
#include <chrono>
#include <ctime>
#include <random>
#include <thread>

static std::string newId(const char *prefix) {
    static std::mt19937_64 rng{std::random_device{}()};
    static const char *hex = "0123456789abcdef";
    std::string s = prefix;
    for (int i = 0; i < 6; i++) s += hex[rng() % 16];
    return s;
}

static std::string nowIso() {
    char buf[32]; time_t t = time(nullptr); strftime(buf, sizeof buf, "%Y-%m-%dT%H:%M:%SZ", gmtime(&t)); return buf;
}

Commands::Commands(StateStore &store, Switcher &sw, ObsRuntime &rt, std::string v)
    : store_(store), sw_(sw), rt_(rt), version_(std::move(v)) {}

json Commands::handle(const json &req) {
    json id = req.value("id", json());
    std::string method = req.value("method", "");
    json params = req.value("params", json::object());
    try {
        json result = dispatch(method, params);
        if (id.is_null()) return json();
        return {{"jsonrpc", "2.0"}, {"id", id}, {"result", result}};
    } catch (const RpcError &e) {
        return {{"jsonrpc", "2.0"}, {"id", id}, {"error", {{"code", -32000}, {"message", e.message}, {"data", {{"code", e.code}}}}}};
    } catch (const std::exception &e) {
        return {{"jsonrpc", "2.0"}, {"id", id}, {"error", {{"code", -32602}, {"message", e.what()}, {"data", {{"code", "INVALID_PARAMS"}}}}}};
    }
}

std::string Commands::requireInput(const json &p) {
    std::string id = p.value("inputId", "");
    if (id.empty() || !sw_.hasInput(id)) throw RpcError{"INPUT_NOT_FOUND", "fonte não encontrada"};
    return id;
}

void Commands::syncMultiview() {
    json s = store_.state();
    std::string pvw = s["preview"]["inputId"].is_string() ? s["preview"]["inputId"].get<std::string>() : "";
    sw_.rebuildMultiview(s["multiview"]["tiles"], pvw);
}

static std::string idOrEmpty(const json &v) { return v.is_string() ? v.get<std::string>() : ""; }

static void swapPvwPgm(json &s) {
    json pvw = s["preview"]["inputId"];
    s["preview"]["inputId"] = s["program"]["inputId"];
    s["program"]["inputId"] = pvw;
    s["program"]["transition"] = nullptr;
}

void Commands::onTransitionDone() {
    std::thread([this] {
        store_.mutate([](json &s) { if (!s["program"]["transition"].is_null()) swapPvwPgm(s); });
        syncMultiview();
    }).detach();
}

void Commands::tickMedia() {
    json s = store_.state();
    std::vector<std::string> ids;
    for (auto &[id, in] : s["inputs"].items()) if (in.value("kind", "") == "media") ids.push_back(id);
    if (ids.empty()) return;
    std::map<std::string, Switcher::Media> info;
    for (auto &id : ids) info[id] = sw_.mediaInfo(id);
    store_.mutate([&](json &st) {
        for (auto &[id, m] : info) {
            if (!st["inputs"].contains(id)) continue;
            json &media = st["inputs"][id]["media"];
            media["durationSeconds"] = m.durationSeconds;
            media["positionSeconds"] = m.positionSeconds;
            media["state"] = m.state;
            st["inputs"][id]["status"] = m.durationSeconds > 0 ? "live" : "starting";
        }
    });
}

json Commands::dispatch(const std::string &method, const json &p) {
    if (method == "session.hello") {
        return {{"protocolVersion", 1}, {"engineVersion", version_},
                {"capabilities", {{"ndi", false}, {"srt", true}, {"decklink", false}, {"metalRuntimeShaders", false}}},
                {"snapshot", store_.snapshot()}};
    }
    if (method == "state.resync") {
        auto patches = store_.patchesSince(p.value("lastRev", -1));
        if (patches) return {{"patches", *patches}};
        return {{"snapshot", store_.snapshot()}};
    }
    if (method == "input.add") {
        std::string kind = p.value("kind", "");
        json config = p.value("config", json::object());
        json s = store_.state();
        std::string name = p.value("name", "");
        if (name.empty()) {
            if (kind == "media" || kind == "image") { std::string path = config.value("path", ""); name = path.substr(path.find_last_of('/') + 1); }
            else if (kind == "synthetic") name = config.value("pattern", "colour") == "bars" ? "Barras" : "Cor";
            else if (kind == "title") name = "Título"; else if (kind == "camera") name = "Câmara"; else if (kind == "screen") name = "Ecrã";
            else name = kind;
        }
        std::string id = newId("in_"), err;
        int rw = s["project"]["raster"]["width"], rh = s["project"]["raster"]["height"];
        if (!sw_.addInput(id, kind, config, name, rw, rh, err)) throw RpcError{err, "não foi possível criar a fonte"};
        bool hasAudio = kind == "media" || kind == "camera" || kind == "srt";
        store_.mutate([&](json &st) {
            json in = {{"id", id}, {"kind", kind}, {"name", name}, {"status", kind == "synthetic" || kind == "title" || kind == "image" ? "live" : "starting"},
                       {"latencyFrames", 0}, {"videoDelayFrames", 0}, {"fit", "fit"},
                       {"colour", {{"brightness", 0}, {"contrast", 1}, {"saturation", 1}}}, {"lowBandwidth", false},
                       {"config", config}, {"hasAudio", hasAudio}};
            if (kind == "media") in["media"] = {{"durationSeconds", 0}, {"positionSeconds", 0}, {"state", "stopped"}, {"loop", config.value("loop", false)}};
            st["inputs"][id] = in;
            st["inputOrder"].push_back(id);
            st["audio"]["inputs"][id] = defaultAudioChannel();
            if (st["program"]["inputId"].is_null()) st["program"]["inputId"] = id;
            else if (st["preview"]["inputId"].is_null()) st["preview"]["inputId"] = id;
            refreshMultiview(st);
        });
        json st = store_.state();
        if (st["program"]["inputId"] == id) sw_.cut(id);
        syncMultiview();
        return {{"inputId", id}};
    }
    if (method == "input.update") {
        std::string id = requireInput(p);
        json s = store_.state();
        std::string kind = s["inputs"][id].value("kind", "");
        store_.mutate([&](json &st) {
            json &in = st["inputs"][id];
            if (p.contains("name")) in["name"] = p["name"];
            if (p.contains("fit")) in["fit"] = p["fit"];
            if (p.contains("config") && p["config"].is_object()) for (auto &[k, v] : p["config"].items()) in["config"][k] = v;
            refreshMultiview(st);
        });
        if (p.contains("config")) sw_.updateInput(id, kind, p["config"]);
        return json::object();
    }
    if (method == "media.play" || method == "media.pause" || method == "media.stop" || method == "media.seek" || method == "media.setLoop") {
        std::string id = requireInput(p);
        sw_.mediaCommand(id, method, p);
        if (method == "media.setLoop") store_.mutate([&](json &st) { st["inputs"][id]["media"]["loop"] = p.value("loop", false); st["inputs"][id]["config"]["loop"] = p.value("loop", false); });
        tickMedia();
        return json::object();
    }
    if (method == "title.setFields") {
        std::string id = requireInput(p);
        json cfg;
        store_.mutate([&](json &st) {
            json &c = st["inputs"][id]["config"];
            if (!c.contains("fields")) c["fields"] = json::object();
            if (p.contains("fields")) for (auto &[k, v] : p["fields"].items()) c["fields"][k] = v;
            cfg = c;
        });
        sw_.updateInput(id, "title", cfg);
        return json::object();
    }
    if (method == "input.remove") {
        std::string id = requireInput(p);
        sw_.removeInput(id);
        store_.mutate([&](json &st) {
            st["inputs"].erase(id);
            json order = json::array();
            for (auto &x : st["inputOrder"]) if (x != id) order.push_back(x);
            st["inputOrder"] = order;
            st["audio"]["inputs"].erase(id);
            if (st["program"]["inputId"] == id) st["program"]["inputId"] = order.empty() ? json() : order[0];
            if (st["preview"]["inputId"] == id) st["preview"]["inputId"] = nullptr;
            for (auto &o : st["overlays"]) if (o["inputId"] == id) { o["inputId"] = nullptr; o["on"] = false; }
            refreshMultiview(st);
        });
        json st = store_.state();
        sw_.cut(idOrEmpty(st["program"]["inputId"]));
        syncMultiview();
        return json::object();
    }
    if (method == "input.reorder") {
        json order = p.value("order", json::array());
        store_.mutate([&](json &st) {
            if (order.size() != st["inputOrder"].size()) throw std::runtime_error("order não corresponde às fontes");
            for (auto &x : order) if (!st["inputs"].contains(x.get<std::string>())) throw std::runtime_error("order com fonte desconhecida");
            st["inputOrder"] = order;
            refreshMultiview(st);
        });
        syncMultiview();
        return json::object();
    }
    if (method == "switcher.setPreview") {
        std::string id = requireInput(p);
        store_.mutate([&](json &st) { st["preview"]["inputId"] = id; });
        syncMultiview();
        return json::object();
    }
    if (method == "switcher.cut") {
        store_.mutate([](json &st) { if (!st["preview"]["inputId"].is_null()) swapPvwPgm(st); });
        json st = store_.state();
        sw_.cut(idOrEmpty(st["program"]["inputId"]));
        syncMultiview();
        return json::object();
    }
    if (method == "switcher.transition") {
        std::string kind = p.value("kind", "fade");
        int frames = std::max(1, p.value("durationFrames", 25));
        json s = store_.state();
        std::string dest = idOrEmpty(s["preview"]["inputId"]);
        if (dest.empty() || !s["program"]["transition"].is_null()) return json::object();
        double fps = s["project"]["raster"].value("fps", 50.0);
        int ms = (int)(frames * 1000.0 / fps);
        json wipe = p.contains("wipe") ? p["wipe"] : json();
        store_.mutate([&](json &st) {
            json t = {{"kind", kind}, {"durationFrames", frames}, {"progress", 0}, {"auto", true}};
            if (!wipe.is_null()) t["wipe"] = wipe;
            if (p.contains("colour")) t["colour"] = p["colour"];
            st["program"]["transition"] = t;
        });
        if (!sw_.transition(kind, ms, p, dest)) onTransitionDone();
        return json::object();
    }
    if (method == "switcher.tbar") {
        double pos = std::min(1.0, std::max(0.0, p.value("position", 0.0)));
        json s = store_.state();
        std::string dest = idOrEmpty(s["preview"]["inputId"]), pgm = idOrEmpty(s["program"]["inputId"]);
        if (dest.empty()) return json::object();
        store_.mutate([&](json &st) {
            if (pos >= 1) { /* a libobs termina a transição e onTransitionDone troca */ st["program"]["transition"]["progress"] = 1; }
            else if (pos > 0) {
                if (st["program"]["transition"].is_null()) st["program"]["transition"] = {{"kind", "fade"}, {"durationFrames", 0}, {"progress", pos}, {"auto", false}};
                else st["program"]["transition"]["progress"] = pos;
            } else st["program"]["transition"] = nullptr;
        });
        sw_.tbar(pos, dest, pgm);
        return json::object();
    }
    if (method == "switcher.ftb") {
        bool on = p.value("on", false);
        store_.mutate([&](json &st) { st["program"]["ftb"] = on; });
        json s = store_.state();
        sw_.ftb(on, idOrEmpty(s["program"]["inputId"]));
        return json::object();
    }
    if (method == "overlay.set") {
        int slot = p.value("slot", 0);
        if (slot < 1 || slot > 4) throw std::runtime_error("slot 1..4");
        store_.mutate([&](json &st) {
            json &o = st["overlays"][slot - 1];
            if (p.contains("inputId")) { o["inputId"] = p["inputId"]; if (p["inputId"].is_null()) o["on"] = false; }
            if (p.contains("on")) o["on"] = p["on"];
            if (p.contains("rect")) o["rect"] = p["rect"];
            if (p.contains("opacity")) o["opacity"] = p["opacity"];
        });
        return json::object(); // TODO: overlays no compositor (cena Program por cima da transição)
    }
    if (method == "audio.setGain" || method == "audio.setMute" || method == "audio.setSolo" || method == "audio.setAFV" || method == "audio.setPan" || method == "audio.setDelay") {
        std::string target = p.value("inputId", p.value("target", "master"));
        store_.mutate([&](json &st) {
            json &ch = target == "master" ? st["audio"]["master"] : st["audio"]["inputs"][target];
            if (method == "audio.setGain") ch["db"] = p.value("db", 0.0);
            if (method == "audio.setMute") ch["mute"] = p.value("on", false);
            if (method == "audio.setSolo") ch["solo"] = p.value("on", false);
            if (method == "audio.setAFV") ch["afv"] = p.value("on", false);
            if (method == "audio.setPan") ch["pan"] = p.value("pan", 0.0);
            if (method == "audio.setDelay") ch["delayMs"] = p.value("ms", 0);
        });
        json s = store_.state();
        if (target != "master" && s["audio"]["inputs"].contains(target)) {
            auto &ch = s["audio"]["inputs"][target];
            sw_.setAudio(target, ch.value("db", 0.0), ch.value("mute", false));
        } // master: a libobs 32 não tem volume global; aplicar como ganho nos codificadores fica para o passo de áudio
        return json::object();
    }
    if (method == "preview.setLayout") {
        std::string layout = p.value("layoutId", "2+8");
        store_.mutate([&](json &st) { st["multiview"]["layoutId"] = layout; refreshMultiview(st); });
        syncMultiview();
        return json::object();
    }
    if (method == "record.setFolder") {
        store_.mutate([&](json &st) { st["recording"]["folder"] = p.value("folder", json()); if (p.contains("container")) st["recording"]["container"] = p["container"]; });
        return json::object();
    }
    if (method == "record.start") { std::string err; if (!startRecording(err)) throw RpcError{"NOT_RUNNING", err}; return json::object(); }
    if (method == "record.stop") { stopRecording(); return json::object(); }
    if (method == "project.setRaster") {
        int w = p.value("width", 1920), h = p.value("height", 1080); double fps = p.value("fps", 50.0);
        int num = fps == 29.97 ? 30000 : fps == 59.94 ? 60000 : (int)fps, den = (fps == 29.97 || fps == 59.94) ? 1001 : 1;
        if (!rt_.resetVideo(w, h, num, den)) throw RpcError{"ALREADY_RUNNING", "não é possível mudar o formato com saídas activas"};
        store_.mutate([&](json &st) { st["project"]["raster"] = {{"width", w}, {"height", h}, {"fps", fps}}; });
        return json::object();
    }
    if (method == "preview.keyframe" || method == "devices.refresh" || method == "projector.set" || method == "audio.setMonitor" ||
        method == "audio.setBus" || method == "audio.setOutputBus" || method == "project.save" || method == "project.load") {
        return json::object();
    }
    if (method == "project.list") return {{"projects", json::array()}};
    if (method == "permissions.status") return store_.state()["permissions"];
    if (method == "output.add" || method == "output.update" || method == "output.remove" || method == "output.start" || method == "output.stop" ||
        method == "audio.addPlugin" || method == "audio.removePlugin" || method == "audio.setPluginBypass" || method == "audio.openPluginUI") {
        throw RpcError{"CAPABILITY_MISSING", "ainda não implementado no motor libobs"};
    }
    if (method == "engine.shutdown") { shutdownRequested = true; return json::object(); }
    throw RpcError{"METHOD_NOT_FOUND", "método desconhecido: " + method};
}

bool Commands::startRecording(std::string &error) {
    std::lock_guard l(recM_);
    if (recOutput_) { error = "já a gravar"; return false; }
    json s = store_.state();
    std::string folder = s["recording"]["folder"].is_string() ? s["recording"]["folder"].get<std::string>() : std::string(getenv("HOME")) + "/Movies/WTV Studio";
    std::string container = s["recording"].value("container", "mp4");
    system(("mkdir -p \"" + folder + "\"").c_str());
    char name[64]; time_t t = time(nullptr); strftime(name, sizeof name, "WTV %Y-%m-%d %H-%M-%S", localtime(&t));
    std::string path = folder + "/" + name + "." + container;

    obs_data_t *vs = obs_data_create();
    obs_data_set_int(vs, "bitrate", 12000); obs_data_set_string(vs, "rate_control", "CBR"); obs_data_set_int(vs, "keyint_sec", 2);
    recVideo_ = obs_video_encoder_create(rt_.videoEncoderId().c_str(), "wtv-rec-h264", vs, nullptr);
    obs_data_release(vs);
    recAudio_ = obs_audio_encoder_create("CoreAudio_AAC", "wtv-rec-aac", nullptr, 0, nullptr);
    if (!recAudio_) recAudio_ = obs_audio_encoder_create("ffmpeg_aac", "wtv-rec-aac", nullptr, 0, nullptr);
    obs_encoder_set_video(recVideo_, obs_get_video());
    obs_encoder_set_audio(recAudio_, obs_get_audio());
    obs_data_t *os = obs_data_create();
    obs_data_set_string(os, "path", path.c_str());
    recOutput_ = obs_output_create("ffmpeg_muxer", "wtv-rec", os, nullptr);
    obs_data_release(os);
    obs_output_set_video_encoder(recOutput_, recVideo_);
    obs_output_set_audio_encoder(recOutput_, recAudio_, 0);
    if (!obs_output_start(recOutput_)) {
        error = obs_output_get_last_error(recOutput_) ? obs_output_get_last_error(recOutput_) : "falha ao iniciar";
        obs_output_release(recOutput_); obs_encoder_release(recVideo_); obs_encoder_release(recAudio_);
        recOutput_ = nullptr; recVideo_ = recAudio_ = nullptr;
        return false;
    }
    store_.mutate([&](json &st) { st["recording"]["status"] = "recording"; st["recording"]["file"] = path; st["recording"]["startedAt"] = nowIso(); });
    return true;
}

void Commands::stopRecording() {
    std::lock_guard l(recM_);
    if (!recOutput_) return;
    store_.mutate([](json &st) { st["recording"]["status"] = "stopping"; });
    obs_output_stop(recOutput_);
    for (int i = 0; i < 100 && obs_output_active(recOutput_); i++) std::this_thread::sleep_for(std::chrono::milliseconds(50));
    obs_output_release(recOutput_); obs_encoder_release(recVideo_); obs_encoder_release(recAudio_);
    recOutput_ = nullptr; recVideo_ = recAudio_ = nullptr;
    store_.mutate([](json &st) { st["recording"]["status"] = "idle"; st["recording"].erase("file"); st["recording"].erase("startedAt"); });
}
