#include "Commands.h"
#include "NDI.h"
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

Commands::Commands(StateStore &store, Switcher &sw, ObsRuntime &rt, Outputs &out, AudioEngine &audio, std::string v)
    : store_(store), sw_(sw), rt_(rt), out_(out), audio_(audio), version_(std::move(v)) {
    store_.mutate([&](json &s) { s["devices"]["audioUnits"] = AudioEngine::catalogue(); s["devices"]["audioOut"] = audio_.monitoringDevices(); s["devices"]["ndiSources"] = NDI::discover(0); });
}

void Commands::applyAudio(const std::string &only) {
    json s = store_.state();
    bool anySolo = false;
    for (auto &[id, ch] : s["audio"]["inputs"].items()) if (ch.value("solo", false)) anySolo = true;
    std::string monBus = s["audio"]["monitor"].value("bus", "master");
    for (auto &[id, ch] : s["audio"]["inputs"].items()) if (only.empty() || only == id) {
        audio_.applyChannel(id, ch, anySolo, monBus);
        sw_.setAlwaysAudible(id, !ch.value("afv", true));
    }
}

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
    std::vector<std::string> mediaIds, liveIds;
    for (auto &[id, in] : s["inputs"].items()) {
        std::string kind = in.value("kind", "");
        if (kind == "media") mediaIds.push_back(id);
        else if (kind != "synthetic" && kind != "title") liveIds.push_back(id);
    }
    if (mediaIds.empty() && liveIds.empty()) return;
    std::map<std::string, Switcher::Media> info;
    for (auto &id : mediaIds) info[id] = sw_.mediaInfo(id);
    std::map<std::string, bool> live;
    for (auto &id : liveIds) live[id] = sw_.hasVideo(id);
    store_.mutate([&](json &st) {
        for (auto &[id, m] : info) {
            if (!st["inputs"].contains(id)) continue;
            json &media = st["inputs"][id]["media"];
            media["durationSeconds"] = m.durationSeconds;
            media["positionSeconds"] = m.positionSeconds;
            media["state"] = m.state;
            st["inputs"][id]["status"] = m.durationSeconds > 0 ? "live" : "starting";
        }
        for (auto &[id, ok] : live) if (st["inputs"].contains(id)) st["inputs"][id]["status"] = ok ? "live" : "noSignal";
    });
}

json Commands::dispatch(const std::string &method, const json &p) {
    if (method == "session.hello") {
        return {{"protocolVersion", 1}, {"engineVersion", version_},
                {"capabilities", {{"ndi", NDI::available()}, {"srt", true}, {"decklink", false}, {"metalRuntimeShaders", false}}},
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
        bool hasAudio = kind == "media" || kind == "camera" || kind == "srt" || kind == "ndi";
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
        audio_.attach(id, sw_.sourceRef(id));
        applyAudio(id);
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
        audio_.detach(id);
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
        for (int i = 1; i <= 4; i++) sw_.setOverlay(i, st["overlays"][i - 1], st["project"]["raster"].value("fps", 50.0));
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
        json s = store_.state();
        sw_.setOverlay(slot, s["overlays"][slot - 1], s["project"]["raster"].value("fps", 50.0));
        return json::object();
    }
    if (method == "audio.setGain" || method == "audio.setMute" || method == "audio.setSolo" || method == "audio.setAFV" || method == "audio.setPan" || method == "audio.setDelay" || method == "audio.setBus") {
        std::string target = p.value("inputId", p.value("target", "master"));
        store_.mutate([&](json &st) {
            json &ch = target == "master" ? st["audio"]["master"] : st["audio"]["inputs"][target];
            if (method == "audio.setGain") ch["db"] = p.value("db", 0.0);
            if (method == "audio.setMute") ch["mute"] = p.value("on", false);
            if (method == "audio.setSolo") ch["solo"] = p.value("on", false);
            if (method == "audio.setAFV") ch["afv"] = p.value("on", false);
            if (method == "audio.setPan") ch["pan"] = std::min(1.0, std::max(-1.0, p.value("pan", 0.0)));
            if (method == "audio.setDelay") ch["delayMs"] = p.value("ms", 0);
            if (method == "audio.setBus") {
                std::string bus = p.value("bus", "master"); bool on = p.value("on", true);
                json buses = json::array();
                for (auto &b : ch.value("buses", json::array({"master"}))) if (b != bus) buses.push_back(b);
                if (on) buses.push_back(bus);
                ch["buses"] = buses;
            }
        });
        if (target == "master") { /* o Master da libobs é a track 1; o ganho global fica para o passo dos codificadores */ }
        else applyAudio(method == "audio.setSolo" ? "" : target);
        return json::object();
    }
    if (method == "audio.setMonitor") {
        store_.mutate([&](json &st) {
            if (p.contains("deviceId")) st["audio"]["monitor"]["deviceId"] = p["deviceId"];
            if (p.contains("db")) st["audio"]["monitor"]["db"] = p["db"];
            if (p.contains("bus")) st["audio"]["monitor"]["bus"] = p["bus"];
        });
        if (p.contains("deviceId")) audio_.setMonitorDevice(p["deviceId"].is_string() ? p["deviceId"].get<std::string>() : "");
        applyAudio();
        return json::object();
    }
    if (method == "audio.setOutputBus") {
        std::string which = p.value("output", "stream"), bus = p.value("bus", "master");
        int idx = bus == "a" ? 1 : bus == "b" ? 2 : 0;
        std::string err;
        if (which == "stream" && !out_.setStreamBus(idx, err)) throw RpcError{err, "parar as saídas antes de mudar o barramento"};
        if (which == "ndi") out_.setNdiBus(idx);
        store_.mutate([&](json &st) { st["audio"]["outputBus"][which] = bus; });
        return json::object();
    }
    if (method == "audio.addPlugin") {
        std::string id = requireInput(p), name, err;
        std::string pid = audio_.addPlugin(id, p.value("componentId", ""), name, err);
        if (pid.empty()) throw RpcError{err, "não foi possível adicionar o plugin"};
        store_.mutate([&](json &st) { st["audio"]["inputs"][id]["plugins"].push_back({{"id", pid}, {"componentId", p.value("componentId", "")}, {"name", name}, {"bypass", false}}); });
        return {{"pluginId", pid}};
    }
    if (method == "audio.removePlugin" || method == "audio.setPluginBypass") {
        std::string id = requireInput(p), pid = p.value("pluginId", "");
        bool ok = method == "audio.removePlugin" ? audio_.removePlugin(id, pid) : audio_.setPluginBypass(id, pid, p.value("on", false));
        if (!ok) throw RpcError{"INVALID_PARAMS", "plugin não encontrado"};
        store_.mutate([&](json &st) {
            json &pl = st["audio"]["inputs"][id]["plugins"]; json next = json::array();
            for (auto &x : pl) { if (x["id"] != pid) next.push_back(x); else if (method == "audio.setPluginBypass") { x["bypass"] = p.value("on", false); next.push_back(x); } }
            pl = next;
        });
        return json::object();
    }
    if (method == "audio.openPluginUI") throw RpcError{"CAPABILITY_MISSING", "os filtros da libobs não têm janela própria; parâmetros por audio.setPluginParam (em breve)"};
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
    if (method == "record.start") { std::string err; if (!out_.startRecording(err)) throw RpcError{"NOT_RUNNING", err}; return json::object(); }
    if (method == "record.stop") { out_.stopRecording(); return json::object(); }
    if (method == "output.add") {
        std::string err, id = out_.add(p.value("kind", ""), p.value("name", ""), p.value("config", json::object()), err);
        if (id.empty()) throw RpcError{err, "não foi possível criar a saída"};
        return {{"outputId", id}};
    }
    if (method == "output.update") { if (!out_.update(p.value("outputId", ""), p)) throw RpcError{"OUTPUT_NOT_FOUND", "saída não encontrada"}; return json::object(); }
    if (method == "output.remove") { std::string err; if (!out_.remove(p.value("outputId", ""), err)) throw RpcError{err, "não foi possível remover"}; return json::object(); }
    if (method == "output.start") { std::string err; if (!out_.start(p.value("outputId", ""), err)) throw RpcError{err, "não foi possível iniciar a saída"}; return json::object(); }
    if (method == "output.stop") { if (!out_.stop(p.value("outputId", ""))) throw RpcError{"OUTPUT_NOT_FOUND", "saída não encontrada"}; return json::object(); }
    if (method == "project.setRaster") {
        int w = p.value("width", 1920), h = p.value("height", 1080); double fps = p.value("fps", 50.0);
        int num = fps == 29.97 ? 30000 : fps == 59.94 ? 60000 : (int)fps, den = (fps == 29.97 || fps == 59.94) ? 1001 : 1;
        if (!rt_.resetVideo(w, h, num, den)) throw RpcError{"ALREADY_RUNNING", "não é possível mudar o formato com saídas activas"};
        store_.mutate([&](json &st) { st["project"]["raster"] = {{"width", w}, {"height", h}, {"fps", fps}}; });
        return json::object();
    }
    if (method == "devices.refresh") {
        json ndi = NDI::discover(1500), aout = audio_.monitoringDevices();
        store_.mutate([&](json &st) { st["devices"]["ndiSources"] = ndi; st["devices"]["audioOut"] = aout; });
        return json::object();
    }
    if (method == "preview.keyframe" || method == "projector.set" || method == "project.save" || method == "project.load") {
        return json::object();
    }
    if (method == "project.list") return {{"projects", json::array()}};
    if (method == "permissions.status") return store_.state()["permissions"];
    if (method == "engine.shutdown") { shutdownRequested = true; return json::object(); }
    throw RpcError{"METHOD_NOT_FOUND", "método desconhecido: " + method};
}

