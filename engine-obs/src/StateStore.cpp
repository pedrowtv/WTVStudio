#include "StateStore.h"
#include <chrono>
#include <ctime>
#include <unistd.h>

StateStore::StateStore(json initial) : state_(std::move(initial)) { state_["rev"] = 0; }

json StateStore::snapshot() { std::lock_guard l(m_); return json{{"rev", rev_}, {"state", state_}}; }
json StateStore::state() { std::lock_guard l(m_); return state_; }
int StateStore::rev() { std::lock_guard l(m_); return rev_; }

void StateStore::mutate(const std::function<void(json &)> &fn) {
    json ops; int from, to;
    {
        std::lock_guard l(m_);
        json next = state_;
        fn(next);
        from = rev_;
        next["rev"] = rev_ + 1;
        ops = json::diff(state_, next);
        if (ops.size() <= 1) return; // só o rev mudou → nada a anunciar
        rev_++; to = rev_;
        state_ = std::move(next);
        history_.emplace_back(to, ops);
        while (history_.size() > 512) history_.pop_front();
    }
    if (listener_) listener_(from, to, ops);
}

std::optional<json> StateStore::patchesSince(int rev) {
    std::lock_guard l(m_);
    if (rev < 0 || rev > rev_) return std::nullopt;
    if (rev == rev_) return json::array();
    json out = json::array();
    for (auto &[to, ops] : history_) {
        if (to <= rev) continue;
        if (to != rev + (int)out.size() + 1) return std::nullopt; // lacuna no histórico
        out.push_back(json{{"fromRev", to - 1}, {"toRev", to}, {"ops", ops}});
    }
    if ((int)out.size() != rev_ - rev) return std::nullopt;
    return out;
}

static std::string nowIso() {
    char buf[32]; time_t t = time(nullptr); strftime(buf, sizeof buf, "%Y-%m-%dT%H:%M:%SZ", gmtime(&t)); return buf;
}

json defaultAudioChannel() {
    return json{{"db", 0}, {"mute", false}, {"solo", false}, {"afv", true}, {"pan", 0}, {"delayMs", 0},
                {"channels", 2}, {"buses", json::array({"master"})}, {"plugins", json::array()}};
}

json defaultState(const std::string &engineVersion, const std::string &bind) {
    json overlay = {{"inputId", nullptr}, {"on", false}, {"rect", {{"x", 0.65}, {"y", 0.05}, {"w", 0.3}, {"h", 0.3}}},
                    {"crop", {{"x", 0}, {"y", 0}, {"w", 1}, {"h", 1}}}, {"opacity", 1}, {"border", nullptr},
                    {"transition", {{"kind", "cut"}, {"durationFrames", 0}}}};
    json s = {
        {"rev", 0},
        {"project", {{"name", "Sem título"}, {"raster", {{"width", 1920}, {"height", 1080}, {"fps", 50}}},
                     {"encoding", {{"videoBitrateKbps", 6000}, {"audioBitrateKbps", 160}, {"keyintSec", 2}, {"profile", "high"}, {"rateControl", "CBR"}}}}},
        {"inputs", json::object()}, {"inputOrder", json::array()},
        {"program", {{"inputId", nullptr}, {"transition", nullptr}, {"ftb", false}}},
        {"preview", {{"inputId", nullptr}}},
        {"overlays", json::array({overlay, overlay, overlay, overlay})},
        {"audio", {{"inputs", json::object()}, {"master", {{"db", 0}, {"mute", false}, {"limiter", true}}},
                   {"monitor", {{"deviceId", nullptr}, {"db", 0}, {"bus", "master"}}},
                   {"outputBus", {{"stream", "master"}, {"ndi", "master"}}},
                   {"tuning", {{"enabled", false}, {"cents", -31.766533}}}}},
        {"outputs", json::object()},
        {"recording", {{"status", "idle"}, {"container", "mp4"}, {"folder", nullptr}, {"iso", json::object()}}},
        {"projector", {{"displayId", nullptr}, {"source", "program"}, {"fullscreen", false}}},
        {"multiview", {{"layoutId", "2+8"}, {"size", {{"width", 1280}, {"height", 720}}}, {"tiles", json::array()}}},
        {"devices", {{"video", json::array()}, {"audioIn", json::array()}, {"audioOut", json::array()}, {"displays", json::array()},
                     {"ndiSources", json::array()}, {"audioUnits", json::array()}}},
        {"permissions", {{"camera", "unknown"}, {"microphone", "unknown"}, {"screen", "unknown"}, {"localNetwork", "unknown"}}},
        {"budget", {{"encoderCapacity1080pFps", 200}, {"encoderUsedPercent", 0}, {"memoryUsedMB", 0}, {"memoryLimitMB", 1800}}},
        {"alarms", json::array()},
        {"system", {{"engineVersion", engineVersion}, {"pid", (int)getpid()}, {"startedAt", nowIso()}, {"bind", bind},
                    {"remoteAccess", false}, {"thermal", "nominal"}}},
    };
    refreshMultiview(s);
    return s;
}

static json tile(const std::string &src, double x, double y, double w, double h, const std::string &label) {
    return json{{"source", src}, {"rect", {{"x", x}, {"y", y}, {"w", w}, {"h", h}}}, {"label", label}};
}

json multiviewTiles(const std::string &layoutId, const json &order, const json &inputs) {
    json t = json::array();
    auto name = [&](const std::string &id) { return inputs.contains(id) ? inputs[id].value("name", id) : id; };
    if (layoutId == "pgm+pvw") {
        t.push_back(tile("preview", 0, 0, 0.5, 1, "PREVIEW"));
        t.push_back(tile("program", 0.5, 0, 0.5, 1, "PROGRAM"));
    } else if (layoutId == "2+16") {
        t.push_back(tile("preview", 0, 0, 0.5, 0.5, "PREVIEW"));
        t.push_back(tile("program", 0.5, 0, 0.5, 0.5, "PROGRAM"));
        for (size_t i = 0; i < order.size() && i < 16; i++)
            t.push_back(tile(order[i], (i % 8) / 8.0, 0.5 + (i / 8) * 0.25, 1 / 8.0, 0.25, name(order[i])));
    } else {
        t.push_back(tile("preview", 0, 0, 0.5, 0.5, "PREVIEW"));
        t.push_back(tile("program", 0.5, 0, 0.5, 0.5, "PROGRAM"));
        for (size_t i = 0; i < order.size() && i < 8; i++)
            t.push_back(tile(order[i], (i % 4) / 4.0, 0.5 + (i / 4) * 0.25, 0.25, 0.25, name(order[i])));
    }
    return t;
}

void refreshMultiview(json &s) {
    s["multiview"]["tiles"] = multiviewTiles(s["multiview"].value("layoutId", "2+8"), s["inputOrder"], s["inputs"]);
}
