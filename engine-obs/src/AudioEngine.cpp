#include "AudioEngine.h"
#include <cmath>
#include <cstring>
#include <random>

static float dbToLin(float db) { return db <= -96.f ? 0.f : powf(10.f, db / 20.f); }

void AudioEngine::start() {
    audio_convert_info conv{48000, AUDIO_FORMAT_FLOAT_PLANAR, SPEAKERS_STEREO, false};
    for (size_t i = 0; i < 3; i++) obs_add_raw_audio_callback(i, &conv, trackCb, &tracks_[i]);
    started_ = true;
}

void AudioEngine::shutdown() {
    if (started_) for (size_t i = 0; i < 3; i++) obs_remove_raw_audio_callback(i, trackCb, &tracks_[i]);
    started_ = false;
    std::lock_guard l(m_);
    for (auto &[id, c] : channels_) {
        if (c->meter) { obs_volmeter_detach_source(c->meter); obs_volmeter_destroy(c->meter); }
        for (auto &[pid, f] : c->plugins) { obs_source_filter_remove(c->src, f); obs_source_release(f); }
        if (c->tuning) { obs_source_filter_remove(c->src, c->tuning); obs_source_release(c->tuning); }
        delete c;
    }
    channels_.clear();
}

void AudioEngine::trackCb(void *param, size_t, struct audio_data *d) {
    auto *t = static_cast<Track *>(param);
    for (int ch = 0; ch < 2; ch++) {
        const float *s = reinterpret_cast<const float *>(d->data[ch]);
        if (!s) { t->peak[ch] = 0; t->rms[ch] = 0; continue; }
        float pk = 0, sum = 0;
        for (uint32_t i = 0; i < d->frames; i++) { float a = fabsf(s[i]); if (a > pk) pk = a; sum += s[i] * s[i]; }
        float prev = t->peak[ch].load();
        t->peak[ch] = pk > prev ? pk : prev * 0.85f; // decaimento rápido mas visível
        t->rms[ch] = d->frames ? sqrtf(sum / d->frames) : 0.f;
    }
}

void AudioEngine::meterCb(void *param, const float magnitude[MAX_AUDIO_CHANNELS], const float peak[MAX_AUDIO_CHANNELS], const float[MAX_AUDIO_CHANNELS]) {
    auto *c = static_cast<Channel *>(param);
    for (int ch = 0; ch < 2; ch++) { c->peak[ch] = dbToLin(peak[ch]); c->rms[ch] = dbToLin(magnitude[ch]); }
}

void AudioEngine::attach(const std::string &id, obs_source_t *src) {
    if (!src || !(obs_source_get_output_flags(src) & OBS_SOURCE_AUDIO)) return;
    std::lock_guard l(m_);
    if (channels_.count(id)) return;
    auto *c = new Channel();
    c->src = src;
    c->meter = obs_volmeter_create(OBS_FADER_LOG);
    obs_volmeter_set_peak_meter_type(c->meter, TRUE_PEAK_METER);
    obs_volmeter_add_callback(c->meter, meterCb, c);
    obs_volmeter_attach_source(c->meter, src);
    obs_source_set_audio_mixers(src, BUS_MASTER);
    channels_[id] = c;
    applyTuning(c);
}

void AudioEngine::applyTuning(Channel *c) {
    if (tuningOn_) {
        obs_data_t *d = obs_data_create();
        obs_data_set_double(d, "cents", tuningCents_);
        if (!c->tuning) {
            c->tuning = obs_source_create_private("wtv_pitch_filter", "wtv-afinacao-global", d);
            if (c->tuning) obs_source_filter_add(c->src, c->tuning);
        } else obs_source_update(c->tuning, d);
        obs_data_release(d);
    } else if (c->tuning) {
        obs_source_filter_remove(c->src, c->tuning);
        obs_source_release(c->tuning);
        c->tuning = nullptr;
    }
}

void AudioEngine::setGlobalTuning(bool enabled, double cents) {
    std::lock_guard l(m_);
    tuningOn_ = enabled; tuningCents_ = cents;
    for (auto &[id, c] : channels_) applyTuning(c);
}

void AudioEngine::detach(const std::string &id) {
    std::lock_guard l(m_);
    auto it = channels_.find(id);
    if (it == channels_.end()) return;
    Channel *c = it->second;
    obs_volmeter_detach_source(c->meter); obs_volmeter_destroy(c->meter);
    for (auto &[pid, f] : c->plugins) { obs_source_filter_remove(c->src, f); obs_source_release(f); }
    if (c->tuning) { obs_source_filter_remove(c->src, c->tuning); obs_source_release(c->tuning); }
    delete c;
    channels_.erase(it);
}

uint32_t AudioEngine::busMask(const json &buses) {
    uint32_t m = 0;
    if (buses.is_array()) for (auto &b : buses) { std::string s = b.is_string() ? b.get<std::string>() : ""; if (s == "master") m |= BUS_MASTER; else if (s == "a") m |= BUS_A; else if (s == "b") m |= BUS_B; }
    return m;
}

void AudioEngine::applyChannel(const std::string &id, const json &ch, bool anySolo, const std::string &monitorBus) {
    std::lock_guard l(m_);
    auto it = channels_.find(id);
    if (it == channels_.end()) return;
    obs_source_t *s = it->second->src;
    double db = ch.value("db", 0.0);
    bool mute = ch.value("mute", false) || (anySolo && !ch.value("solo", false));
    obs_source_set_volume(s, db <= -60 ? 0.f : obs_db_to_mul((float)db));
    obs_source_set_muted(s, mute);
    obs_source_set_balance_value(s, (float)((ch.value("pan", 0.0) + 1.0) / 2.0));
    obs_source_set_sync_offset(s, (int64_t)ch.value("delayMs", 0) * 1000000LL);
    uint32_t mask = busMask(ch.value("buses", json::array({"master"})));
    obs_source_set_audio_mixers(s, mask ? mask : BUS_MASTER);
    uint32_t monMask = monitorBus == "a" ? BUS_A : monitorBus == "b" ? BUS_B : BUS_MASTER;
    obs_source_set_monitoring_type(s, (mask & monMask) ? OBS_MONITORING_TYPE_MONITOR_AND_OUTPUT : OBS_MONITORING_TYPE_NONE);
}

void AudioEngine::setMonitorDevice(const std::string &deviceId) {
    if (deviceId.empty()) { obs_set_audio_monitoring_device("Default", "default"); return; }
    struct Ctx { std::string id, name; } ctx{deviceId, ""};
    obs_enum_audio_monitoring_devices([](void *p, const char *name, const char *id) { auto *c = (Ctx *)p; if (c->id == id) { c->name = name; return false; } return true; }, &ctx);
    obs_set_audio_monitoring_device(ctx.name.empty() ? deviceId.c_str() : ctx.name.c_str(), deviceId.c_str());
}

json AudioEngine::inputDevices() {
    json out = json::array();
    obs_properties_t *ps = obs_get_source_properties("coreaudio_input_capture");
    if (!ps) return out;
    obs_property_t *p = obs_properties_get(ps, "device_id");
    for (size_t i = 0; p && i < obs_property_list_item_count(p); i++) {
        std::string id = obs_property_list_item_string(p, i) ? obs_property_list_item_string(p, i) : "";
        out.push_back({{"uid", id}, {"name", obs_property_list_item_name(p, i)}, {"channels", 2}, {"sampleRate", 48000}, {"isDefault", id == "default"}});
    }
    obs_properties_destroy(ps);
    return out;
}

json AudioEngine::monitoringDevices() {
    json out = json::array();
    obs_enum_audio_monitoring_devices([](void *p, const char *name, const char *id) {
        ((json *)p)->push_back({{"uid", id}, {"name", name}, {"channels", 2}, {"sampleRate", 48000}, {"isDefault", std::string(id) == "default"}});
        return true;
    }, &out);
    return out;
}

static const struct { const char *filter; const char *name; } kPlugins[] = {
    {"wtv_pitch_filter", "Afinação 432 Hz (pitch)"},
    {"noise_suppress_filter", "Supressão de ruído (RNNoise)"}, {"noise_gate_filter", "Noise gate"},
    {"compressor_filter", "Compressor"}, {"limiter_filter", "Limitador"}, {"expander_filter", "Expander"},
    {"upward_compressor_filter", "Compressor ascendente"}, {"basic_eq_filter", "Equalizador 3 bandas"}, {"gain_filter", "Ganho"},
};

json AudioEngine::catalogue() {
    json out = json::array();
    for (auto &p : kPlugins) if (obs_get_latest_input_type_id(p.filter) || obs_is_source_configurable(p.filter) || std::string(p.filter) == "wtv_pitch_filter")
        out.push_back({{"id", std::string("obs:") + p.filter}, {"name", p.name}, {"manufacturer", "OBS"}});
    return out;
}

std::string AudioEngine::addPlugin(const std::string &id, const std::string &componentId, std::string &name, std::string &error) {
    if (componentId.rfind("obs:", 0) != 0) { error = "CAPABILITY_MISSING"; return ""; }
    std::string filterId = componentId.substr(4);
    std::lock_guard l(m_);
    auto it = channels_.find(id);
    if (it == channels_.end()) { error = "INPUT_NOT_FOUND"; return ""; }
    static std::mt19937_64 rng{std::random_device{}()};
    std::string pid = "pl_"; for (int i = 0; i < 6; i++) pid += "0123456789abcdef"[rng() % 16];
    obs_data_t *st = obs_data_create();
    if (filterId == "noise_suppress_filter") obs_data_set_string(st, "method", "rnnoise");
    obs_source_t *f = obs_source_create_private(filterId.c_str(), pid.c_str(), st);
    obs_data_release(st);
    if (!f) { error = "DEVICE_UNAVAILABLE"; return ""; }
    obs_source_filter_add(it->second->src, f);
    it->second->plugins[pid] = f;
    name = filterId;
    for (auto &p : kPlugins) if (filterId == p.filter) name = p.name;
    return pid;
}

bool AudioEngine::removePlugin(const std::string &id, const std::string &pid) {
    std::lock_guard l(m_);
    auto it = channels_.find(id);
    if (it == channels_.end()) return false;
    auto f = it->second->plugins.find(pid);
    if (f == it->second->plugins.end()) return false;
    obs_source_filter_remove(it->second->src, f->second);
    obs_source_release(f->second);
    it->second->plugins.erase(f);
    return true;
}

bool AudioEngine::setPluginBypass(const std::string &id, const std::string &pid, bool bypass) {
    std::lock_guard l(m_);
    auto it = channels_.find(id);
    if (it == channels_.end()) return false;
    auto f = it->second->plugins.find(pid);
    if (f == it->second->plugins.end()) return false;
    obs_source_set_enabled(f->second, !bypass);
    return true;
}

uint16_t AudioEngine::f16(float v) {
    if (!(v > 0)) return 0;
    if (v > 65504.f) v = 65504.f;
    uint32_t bits; memcpy(&bits, &v, 4);
    uint32_t exp = (bits >> 23) & 0xFF, mant = bits & 0x7FFFFF;
    int e = (int)exp - 127 + 15;
    if (e <= 0) { if (e < -10) return 0; mant |= 0x800000; uint32_t shift = 14 - e; return (uint16_t)(mant >> shift); }
    return (uint16_t)((e << 10) | (mant >> 13));
}

std::vector<uint8_t> AudioEngine::metersFrame(const json &order) {
    std::lock_guard l(m_);
    std::vector<uint8_t> out;
    auto put = [&](uint8_t idx, float pl, float pr, float rl, float rr) {
        out.push_back(idx);
        for (float v : {pl, pr, rl, rr}) { uint16_t h = f16(v); out.push_back(h & 0xFF); out.push_back(h >> 8); }
    };
    out.resize(2);
    uint16_t count = 0;
    for (size_t i = 0; i < order.size() && i < 250; i++) {
        auto it = channels_.find(order[i].get<std::string>());
        if (it == channels_.end()) continue;
        Channel *c = it->second;
        bool muted = obs_source_muted(c->src);
        float g = muted ? 0.f : 1.f;
        put((uint8_t)i, g * c->peak[0].load(), g * c->peak[1].load(), g * c->rms[0].load(), g * c->rms[1].load()); count++;
    }
    put(253, tracks_[2].peak[0], tracks_[2].peak[1], tracks_[2].rms[0], tracks_[2].rms[1]);
    put(254, tracks_[1].peak[0], tracks_[1].peak[1], tracks_[1].rms[0], tracks_[1].rms[1]);
    put(255, tracks_[0].peak[0], tracks_[0].peak[1], tracks_[0].rms[0], tracks_[0].rms[1]);
    count += 3;
    out[0] = count & 0xFF; out[1] = count >> 8;
    return out;
}

static json dataToJson(obs_data_t *d) {
    json out = json::object();
    for (obs_data_item_t *it = obs_data_first(d); it; obs_data_item_next(&it)) {
        const char *k = obs_data_item_get_name(it);
        switch (obs_data_item_gettype(it)) {
            case OBS_DATA_NUMBER: out[k] = obs_data_item_numtype(it) == OBS_DATA_NUM_INT ? json((long long)obs_data_item_get_int(it)) : json(obs_data_item_get_double(it)); break;
            case OBS_DATA_STRING: out[k] = obs_data_item_get_string(it); break;
            case OBS_DATA_BOOLEAN: out[k] = obs_data_item_get_bool(it); break;
            default: break;
        }
    }
    return out;
}

json AudioEngine::pluginParams(const std::string &id, const std::string &pid) {
    std::lock_guard l(m_);
    auto it = channels_.find(id);
    if (it == channels_.end()) return json();
    auto f = it->second->plugins.find(pid);
    if (f == it->second->plugins.end()) return json();
    obs_source_t *filter = f->second;
    obs_data_t *settings = obs_source_get_settings(filter);
    obs_data_t *defaults = obs_data_get_defaults(settings);
    json values = dataToJson(defaults);
    for (auto &[k, v] : dataToJson(settings).items()) values[k] = v;
    obs_data_release(defaults); obs_data_release(settings);
    json props = json::array();
    obs_properties_t *ps = obs_source_properties(filter);
    for (obs_property_t *p = obs_properties_first(ps); p; obs_property_next(&p)) {
        if (!obs_property_visible(p)) continue;
        json e = {{"name", obs_property_name(p)}, {"description", obs_property_description(p) ? obs_property_description(p) : obs_property_name(p)}};
        switch (obs_property_get_type(p)) {
            case OBS_PROPERTY_FLOAT: e["type"] = "float"; e["min"] = obs_property_float_min(p); e["max"] = obs_property_float_max(p); e["step"] = obs_property_float_step(p); break;
            case OBS_PROPERTY_INT: e["type"] = "int"; e["min"] = obs_property_int_min(p); e["max"] = obs_property_int_max(p); e["step"] = obs_property_int_step(p); break;
            case OBS_PROPERTY_BOOL: e["type"] = "bool"; break;
            case OBS_PROPERTY_TEXT: e["type"] = "text"; break;
            case OBS_PROPERTY_LIST: {
                e["type"] = "list"; json opts = json::array();
                enum obs_combo_format fmt = obs_property_list_format(p);
                for (size_t i = 0; i < obs_property_list_item_count(p); i++) {
                    json o = {{"name", obs_property_list_item_name(p, i)}};
                    if (fmt == OBS_COMBO_FORMAT_INT) o["value"] = (long long)obs_property_list_item_int(p, i);
                    else if (fmt == OBS_COMBO_FORMAT_FLOAT) o["value"] = obs_property_list_item_float(p, i);
                    else o["value"] = obs_property_list_item_string(p, i);
                    opts.push_back(o);
                }
                e["options"] = opts; break;
            }
            default: continue;
        }
        props.push_back(e);
    }
    obs_properties_destroy(ps);
    return {{"properties", props}, {"values", values}};
}

bool AudioEngine::setPluginParams(const std::string &id, const std::string &pid, const json &params) {
    std::lock_guard l(m_);
    auto it = channels_.find(id);
    if (it == channels_.end()) return false;
    auto f = it->second->plugins.find(pid);
    if (f == it->second->plugins.end() || !params.is_object()) return false;
    obs_data_t *d = obs_data_create();
    for (auto &[k, v] : params.items()) {
        if (v.is_boolean()) obs_data_set_bool(d, k.c_str(), v.get<bool>());
        else if (v.is_number_integer()) obs_data_set_int(d, k.c_str(), v.get<long long>());
        else if (v.is_number()) obs_data_set_double(d, k.c_str(), v.get<double>());
        else if (v.is_string()) obs_data_set_string(d, k.c_str(), v.get<std::string>().c_str());
    }
    obs_source_update(f->second, d);
    obs_data_release(d);
    return true;
}
