#include "Switcher.h"
#include <cstdio>
#include <cstring>

static uint32_t parseColour(const std::string &hex, uint32_t fallback) {
    if (hex.size() != 7 || hex[0] != '#') return fallback;
    unsigned r, g, b;
    if (sscanf(hex.c_str() + 1, "%02x%02x%02x", &r, &g, &b) != 3) return fallback;
    return 0xFF000000u | (b << 16) | (g << 8) | r; // ABGR como a libobs espera
}

bool Switcher::init(int baseW, int baseH, int mvW, int mvH) {
    baseW_ = baseW; baseH_ = baseH;
    const char *kinds[] = {"cut_transition", "fade_transition", "wipe_transition", "fade_to_color_transition"};
    for (auto k : kinds) {
        obs_source_t *t = obs_source_create_private(k, k, nullptr);
        if (!t) { fprintf(stderr, "transição %s indisponível\n", k); return false; }
        signal_handler_connect(obs_source_get_signal_handler(t), "transition_stop", transitionStopped, this);
        transitions_[k] = t;
    }
    current_ = transitions_["cut_transition"];
    programScene_ = obs_scene_create_private("program");
    programItem_ = obs_scene_add(programScene_, current_);
    for (int i = 0; i < 4; i++) {
        Overlay &o = overlays_[i];
        std::string n = "overlay" + std::to_string(i + 1);
        o.fade = obs_source_create_private("fade_transition", n.c_str(), nullptr);
        o.scene = obs_scene_create_private((n + "-scene").c_str());
        obs_data_t *fs = obs_data_create();
        obs_data_set_double(fs, "opacity", 1.0);
        o.opacity = obs_source_create_private("color_filter_v2", (n + "-opacity").c_str(), fs);
        obs_data_release(fs);
        obs_source_filter_add(obs_scene_get_source(o.scene), o.opacity);
        obs_scene_add(programScene_, o.fade);
    }
    obs_set_output_source(0, obs_scene_get_source(programScene_));

    obs_data_t *bs = obs_data_create();
    obs_data_set_int(bs, "color", 0xFF000000); obs_data_set_int(bs, "width", baseW); obs_data_set_int(bs, "height", baseH);
    black_ = obs_source_create_private("color_source_v3", "ftb", bs);
    obs_data_release(bs);

    mvScene_ = obs_scene_create_private("multiview");
    mvView_ = obs_view_create();
    obs_view_set_source(mvView_, 0, obs_scene_get_source(mvScene_));
    obs_video_info ovi{};
    obs_get_video_info(&ovi);
    ovi.base_width = baseW; ovi.base_height = baseH;
    ovi.output_width = mvW; ovi.output_height = mvH;
    mvVideo_ = obs_view_add2(mvView_, &ovi);
    return mvVideo_ != nullptr;
}

void Switcher::shutdown() {
    std::lock_guard l(m_);
    obs_set_output_source(0, nullptr);
    for (auto &o : overlays_) {
        if (o.scene) { obs_scene_release(o.scene); o.scene = nullptr; }
        if (o.opacity) { obs_source_release(o.opacity); o.opacity = nullptr; }
        if (o.fade) { obs_source_release(o.fade); o.fade = nullptr; }
    }
    if (programScene_) { obs_scene_release(programScene_); programScene_ = nullptr; }
    if (mvView_) { obs_view_set_source(mvView_, 0, nullptr); obs_view_remove(mvView_); obs_view_destroy(mvView_); mvView_ = nullptr; }
    if (mvScene_) { obs_scene_release(mvScene_); mvScene_ = nullptr; }
    for (auto &[id, s] : inputs_) obs_source_release(s);
    inputs_.clear();
    for (auto &[k, t] : transitions_) obs_source_release(t);
    transitions_.clear();
    if (black_) { obs_source_release(black_); black_ = nullptr; }
}

obs_source_t *Switcher::source(const std::string &id) {
    auto it = inputs_.find(id);
    return it == inputs_.end() ? nullptr : it->second;
}

bool Switcher::hasInput(const std::string &id) { std::lock_guard l(m_); return inputs_.count(id) > 0; }

bool Switcher::addInput(const std::string &id, const std::string &kind, const json &c, const std::string &name, int rw, int rh, std::string &error) {
    obs_data_t *s = obs_data_create();
    std::string obsId;
    if (kind == "synthetic") {
        obsId = "color_source_v3";
        std::string pattern = c.value("pattern", "colour");
        uint32_t fallback = pattern == "bars" ? 0xFFC06020 : pattern == "sync" ? 0xFF303030 : pattern == "testPattern" ? 0xFF40A040 : 0xFF808080;
        obs_data_set_int(s, "color", parseColour(c.value("colour", ""), fallback));
        obs_data_set_int(s, "width", rw); obs_data_set_int(s, "height", rh);
    } else if (kind == "media") {
        obsId = "ffmpeg_source";
        obs_data_set_bool(s, "is_local_file", true);
        obs_data_set_string(s, "local_file", c.value("path", "").c_str());
        obs_data_set_bool(s, "looping", c.value("loop", false));
        obs_data_set_bool(s, "hw_decode", true);
        obs_data_set_bool(s, "restart_on_activate", false);
        obs_data_set_int(s, "speed_percent", (int)(c.value("speed", 1.0) * 100));
    } else if (kind == "srt") {
        obsId = "ffmpeg_source";
        obs_data_set_bool(s, "is_local_file", false);
        obs_data_set_string(s, "input", c.value("url", "").c_str());
        obs_data_set_string(s, "input_format", "mpegts");
        obs_data_set_bool(s, "hw_decode", true);
        obs_data_set_bool(s, "restart_on_activate", false); // as fontes correm sempre, não só quando estão em Program
        obs_data_set_int(s, "reconnect_delay_sec", 2);
    } else if (kind == "image") {
        obsId = "image_source";
        obs_data_set_string(s, "file", c.value("path", "").c_str());
    } else if (kind == "title") {
        obsId = "text_ft2_source_v2";
        std::string text = c.value("template", "");
        if (c.contains("fields") && c["fields"].is_object()) {
            for (auto &[k, v] : c["fields"].items()) {
                if (v.is_string()) {
                    std::string key = "{" + k + "}";
                    for (size_t p; (p = text.find(key)) != std::string::npos;) text.replace(p, key.size(), v.get<std::string>());
                }
            }
            if (text.empty() && c["fields"].contains("text")) text = c["fields"]["text"].get<std::string>();
        }
        obs_data_set_string(s, "text", text.c_str());
        obs_data_t *font = obs_data_create();
        obs_data_set_string(font, "face", "Helvetica"); obs_data_set_int(font, "size", 72);
        obs_data_set_obj(s, "font", font); obs_data_release(font);
        obs_data_set_int(s, "color1", 0xFFFFFFFF); obs_data_set_int(s, "color2", 0xFFFFFFFF);
    } else if (kind == "camera") {
        obsId = "macos-avcapture";
        obs_data_set_string(s, "device", c.value("uniqueId", "").c_str());
    } else if (kind == "screen") {
        obsId = "screen_capture";
        obs_data_set_int(s, "type", 0);
        obs_data_set_bool(s, "show_cursor", c.value("showCursor", true));
    } else {
        obs_data_release(s);
        error = "CAPABILITY_MISSING";
        return false;
    }
    obs_source_t *src = obs_source_create(obsId.c_str(), name.c_str(), s, nullptr);
    obs_data_release(s);
    if (!src) { error = "DEVICE_UNAVAILABLE"; return false; }
    std::lock_guard l(m_);
    inputs_[id] = src;
    return true;
}

void Switcher::updateInput(const std::string &id, const std::string &kind, const json &c) {
    std::lock_guard l(m_);
    obs_source_t *src = source(id);
    if (!src) return;
    obs_data_t *s = obs_data_create();
    if (kind == "media") {
        if (c.contains("path")) obs_data_set_string(s, "local_file", c["path"].get<std::string>().c_str());
        if (c.contains("loop")) obs_data_set_bool(s, "looping", c["loop"].get<bool>());
        if (c.contains("speed")) obs_data_set_int(s, "speed_percent", (int)(c["speed"].get<double>() * 100));
    } else if (kind == "image" && c.contains("path")) {
        obs_data_set_string(s, "file", c["path"].get<std::string>().c_str());
    } else if (kind == "synthetic" && c.contains("colour")) {
        obs_data_set_int(s, "color", parseColour(c["colour"].get<std::string>(), 0xFF808080));
    } else if (kind == "title") {
        std::string text = c.value("template", "");
        if (c.contains("fields") && c["fields"].contains("text")) text = c["fields"]["text"].get<std::string>();
        obs_data_set_string(s, "text", text.c_str());
    }
    obs_source_update(src, s);
    obs_data_release(s);
}

void Switcher::removeInput(const std::string &id) {
    std::lock_guard l(m_);
    auto it = inputs_.find(id);
    if (it == inputs_.end()) return;
    obs_source_t *src = it->second;
    inputs_.erase(it);
    if (obs_transition_get_active_source(current_) == src) obs_transition_set(current_, nullptr);
    obs_source_remove(src);
    obs_source_release(src);
}

void Switcher::cut(const std::string &programId) {
    std::lock_guard l(m_);
    pending_ = false;
    obs_transition_set(current_, ftb_ ? black_ : source(programId));
}

obs_source_t *Switcher::transitionFor(const std::string &kind, const json &p) {
    obs_source_t *t;
    if (kind == "wipe") {
        t = transitions_["wipe_transition"];
        std::string dir = p.contains("wipe") ? p["wipe"].value("direction", "left") : "left";
        double soft = p.contains("wipe") ? p["wipe"].value("softness", 0.05) : 0.05;
        const char *img = "linear-h.png"; bool inv = false;
        if (dir == "right") { img = "linear-h.png"; inv = true; }
        else if (dir == "up") { img = "linear-v.png"; inv = true; }
        else if (dir == "down") img = "linear-v.png";
        else if (dir == "box") img = "box-topleft.png";
        else if (dir == "circle") img = "iris.png";
        else if (dir == "diagonalUp") img = "linear-topright.png";
        else if (dir == "diagonalDown") img = "linear-topleft.png";
        obs_data_t *s = obs_data_create();
        obs_data_set_string(s, "luma_image", img); obs_data_set_bool(s, "luma_invert", inv); obs_data_set_double(s, "luma_softness", soft);
        obs_source_update(t, s); obs_data_release(s);
    } else if (kind == "dip") {
        t = transitions_["fade_to_color_transition"];
        obs_data_t *s = obs_data_create();
        obs_data_set_int(s, "color", parseColour(p.value("colour", "#000000"), 0xFF000000)); obs_data_set_int(s, "switch_point", 50);
        obs_source_update(t, s); obs_data_release(s);
    } else {
        t = transitions_["fade_transition"];
    }
    return t;
}

void Switcher::swapTransition(obs_source_t *next) {
    if (next == current_) return;
    obs_transition_swap_begin(next, current_);
    obs_sceneitem_remove(programItem_);
    programItem_ = obs_scene_add(programScene_, next);
    obs_sceneitem_set_order(programItem_, OBS_ORDER_MOVE_BOTTOM);
    obs_transition_swap_end(next, current_);
    current_ = next;
}

bool Switcher::transition(const std::string &kind, int durationMs, const json &params, const std::string &destId) {
    std::lock_guard l(m_);
    obs_source_t *dest = source(destId);
    if (!dest || ftb_) return false;
    swapTransition(transitionFor(kind, params));
    pending_ = true;
    return obs_transition_start(current_, OBS_TRANSITION_MODE_AUTO, (uint32_t)durationMs, dest);
}

void Switcher::tbar(double pos, const std::string &destId, const std::string &programId) {
    std::lock_guard l(m_);
    if (ftb_) return;
    if (pos <= 0) { pending_ = false; obs_transition_set(current_, source(programId)); return; }
    obs_source_t *dest = source(destId);
    if (!dest) return;
    if (!pending_) {
        swapTransition(transitions_["fade_transition"]);
        pending_ = true;
        obs_transition_start(current_, OBS_TRANSITION_MODE_MANUAL, 0, dest);
    }
    obs_transition_set_manual_time(current_, (float)pos);
}

void Switcher::ftb(bool on, const std::string &programId) {
    std::lock_guard l(m_);
    ftb_ = on;
    pending_ = false;
    swapTransition(transitions_["fade_transition"]);
    obs_transition_start(current_, OBS_TRANSITION_MODE_AUTO, 300, on ? black_ : source(programId));
}

void Switcher::transitionStopped(void *data, calldata_t *) {
    auto *self = static_cast<Switcher *>(data);
    bool fire;
    { std::lock_guard l(self->m_); fire = self->pending_; self->pending_ = false; }
    if (fire && self->onTransitionDone) self->onTransitionDone();
}

void Switcher::rebuildMultiview(const json &tiles, const std::string &previewId) {
    std::lock_guard l(m_);
    obs_scene_enum_items(mvScene_, [](obs_scene_t *, obs_sceneitem_t *item, void *) { obs_sceneitem_remove(item); return true; }, nullptr);
    for (auto &t : tiles) {
        std::string src = t.value("source", "");
        obs_source_t *s = src == "program" ? obs_scene_get_source(programScene_) : src == "preview" ? source(previewId) : source(src);
        if (!s) continue;
        obs_sceneitem_t *item = obs_scene_add(mvScene_, s);
        auto r = t["rect"];
        vec2 pos{(float)(r.value("x", 0.0) * baseW_), (float)(r.value("y", 0.0) * baseH_)};
        vec2 bounds{(float)(r.value("w", 0.0) * baseW_), (float)(r.value("h", 0.0) * baseH_)};
        obs_sceneitem_set_bounds_type(item, OBS_BOUNDS_SCALE_INNER);
        obs_sceneitem_set_bounds_alignment(item, OBS_ALIGN_CENTER);
        obs_sceneitem_set_alignment(item, OBS_ALIGN_TOP | OBS_ALIGN_LEFT);
        obs_sceneitem_set_pos(item, &pos);
        obs_sceneitem_set_bounds(item, &bounds);
    }
}

void Switcher::setAudio(const std::string &id, double db, bool mute) {
    std::lock_guard l(m_);
    if (obs_source_t *s = source(id)) {
        obs_source_set_volume(s, db <= -60 ? 0.f : (float)obs_db_to_mul((float)db));
        obs_source_set_muted(s, mute);
    }
}

void Switcher::mediaCommand(const std::string &id, const std::string &cmd, const json &p) {
    std::lock_guard l(m_);
    obs_source_t *s = source(id);
    if (!s) return;
    if (cmd == "media.play") {
        if (obs_source_media_get_state(s) == OBS_MEDIA_STATE_PAUSED) obs_source_media_play_pause(s, false);
        else obs_source_media_restart(s);
    } else if (cmd == "media.pause") obs_source_media_play_pause(s, true);
    else if (cmd == "media.stop") obs_source_media_stop(s);
    else if (cmd == "media.seek") obs_source_media_set_time(s, (int64_t)(p.value("seconds", 0.0) * 1000));
    else if (cmd == "media.setLoop") {
        obs_data_t *d = obs_data_create(); obs_data_set_bool(d, "looping", p.value("loop", false));
        obs_source_update(s, d); obs_data_release(d);
    }
}

Switcher::Media Switcher::mediaInfo(const std::string &id) {
    std::lock_guard l(m_);
    Media m;
    obs_source_t *s = source(id);
    if (!s) return m;
    m.durationSeconds = obs_source_media_get_duration(s) / 1000.0;
    m.positionSeconds = obs_source_media_get_time(s) / 1000.0;
    switch (obs_source_media_get_state(s)) {
        case OBS_MEDIA_STATE_PLAYING: case OBS_MEDIA_STATE_OPENING: case OBS_MEDIA_STATE_BUFFERING: m.state = "playing"; break;
        case OBS_MEDIA_STATE_PAUSED: m.state = "paused"; break;
        default: m.state = "stopped";
    }
    return m;
}

void Switcher::setOverlay(int slot, const json &ov, double fps) {
    if (slot < 1 || slot > 4) return;
    std::lock_guard l(m_);
    Overlay &o = overlays_[slot - 1];
    std::string inputId = ov["inputId"].is_string() ? ov["inputId"].get<std::string>() : "";
    bool on = ov.value("on", false) && !inputId.empty() && source(inputId);
    // Conteúdo do slot: um item com a fonte dentro do rectângulo pedido
    obs_scene_enum_items(o.scene, [](obs_scene_t *, obs_sceneitem_t *item, void *) { obs_sceneitem_remove(item); return true; }, nullptr);
    if (obs_source_t *src = source(inputId)) {
        obs_sceneitem_t *item = obs_scene_add(o.scene, src);
        auto r = ov["rect"];
        vec2 pos{(float)(r.value("x", 0.0) * baseW_), (float)(r.value("y", 0.0) * baseH_)};
        vec2 bounds{(float)(r.value("w", 1.0) * baseW_), (float)(r.value("h", 1.0) * baseH_)};
        obs_sceneitem_set_bounds_type(item, OBS_BOUNDS_SCALE_INNER);
        obs_sceneitem_set_bounds_alignment(item, OBS_ALIGN_CENTER);
        obs_sceneitem_set_alignment(item, OBS_ALIGN_TOP | OBS_ALIGN_LEFT);
        obs_sceneitem_set_pos(item, &pos);
        obs_sceneitem_set_bounds(item, &bounds);
        auto c = ov.value("crop", json::object());
        obs_sceneitem_crop crop{};
        uint32_t sw = obs_source_get_width(src), sh = obs_source_get_height(src);
        crop.left = (int)(c.value("x", 0.0) * sw); crop.top = (int)(c.value("y", 0.0) * sh);
        crop.right = (int)((1 - c.value("x", 0.0) - c.value("w", 1.0)) * sw); crop.bottom = (int)((1 - c.value("y", 0.0) - c.value("h", 1.0)) * sh);
        if (crop.left || crop.top || crop.right > 0 || crop.bottom > 0) obs_sceneitem_set_crop(item, &crop);
    }
    obs_data_t *fs = obs_data_create();
    obs_data_set_double(fs, "opacity", std::min(1.0, std::max(0.0, ov.value("opacity", 1.0))));
    obs_source_update(o.opacity, fs); obs_data_release(fs);
    // Liga/desliga com a transição do slot (cut = 0 ms)
    if (on != o.on || inputId != o.inputId) {
        std::string kind = ov.contains("transition") ? ov["transition"].value("kind", "cut") : "cut";
        int frames = ov.contains("transition") ? ov["transition"].value("durationFrames", 0) : 0;
        uint32_t ms = kind == "cut" ? 0 : (uint32_t)(frames * 1000.0 / fps);
        obs_source_t *dest = on ? obs_scene_get_source(o.scene) : nullptr;
        if (ms == 0) obs_transition_set(o.fade, dest);
        else obs_transition_start(o.fade, OBS_TRANSITION_MODE_AUTO, ms, dest);
    }
    o.on = on; o.inputId = inputId;
}

bool Switcher::hasVideo(const std::string &id) {
    std::lock_guard l(m_);
    obs_source_t *s = source(id);
    return s && obs_source_get_width(s) > 0;
}
