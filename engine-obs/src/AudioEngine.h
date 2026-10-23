#pragma once
#include "StateStore.h"
#include <obs.h>
#include <atomic>
#include <cstdint>
#include <map>
#include <mutex>
#include <string>
#include <vector>

/// Áudio sobre a libobs: VU por fonte (obs_volmeter) e por barramento (callbacks das tracks),
/// ganho/pan/atraso/mute/solo/AFV, barramentos Master/A/B = tracks 1/2/3, filtros de áudio
/// da libobs como "plugins" (RNNoise, compressor, limitador, EQ, gate, expander, ganho) e monitorização.
class AudioEngine {
public:
    static constexpr uint32_t BUS_MASTER = 1, BUS_A = 2, BUS_B = 4;

    void start();
    void shutdown();
    void attach(const std::string &inputId, obs_source_t *src);
    void detach(const std::string &inputId);

    /// Aplica o AudioChannelState a uma fonte (volume, mute efectivo com solo, pan, atraso, buses, AFV, monitor).
    void applyChannel(const std::string &inputId, const json &channel, bool anySolo, const std::string &monitorBus);
    void setMonitorDevice(const std::string &deviceId);

    std::string addPlugin(const std::string &inputId, const std::string &componentId, std::string &name, std::string &error);
    bool removePlugin(const std::string &inputId, const std::string &pluginId);
    bool setPluginBypass(const std::string &inputId, const std::string &pluginId, bool bypass);
    json pluginParams(const std::string &inputId, const std::string &pluginId);          // {properties:[...], values:{...}}
    bool setPluginParams(const std::string &inputId, const std::string &pluginId, const json &params);

    static json catalogue();       // devices.audioUnits
    json monitoringDevices();      // devices.audioOut

    /// Frame binário do stream 16: u16 count + count × {u8 índice, f16 peakL, peakR, rmsL, rmsR}; 255/254/253 = Master/A/B.
    std::vector<uint8_t> metersFrame(const json &inputOrder);
    static uint32_t busMask(const json &buses);

private:
    struct Channel {
        obs_source_t *src = nullptr;
        obs_volmeter_t *meter = nullptr;
        std::atomic<float> peak[2]{0, 0}, rms[2]{0, 0};
        bool forcedActive = false; // AFV desligado → obs_source_inc_active
        std::map<std::string, obs_source_t *> plugins;
    };
    struct Track { std::atomic<float> peak[2]{0, 0}, rms[2]{0, 0}; };
    static void meterCb(void *param, const float magnitude[MAX_AUDIO_CHANNELS], const float peak[MAX_AUDIO_CHANNELS], const float inputPeak[MAX_AUDIO_CHANNELS]);
    static void trackCb(void *param, size_t mixIdx, struct audio_data *data);
    static uint16_t f16(float v);

    std::mutex m_;
    std::map<std::string, Channel *> channels_;
    Track tracks_[3];
    bool started_ = false;
};
