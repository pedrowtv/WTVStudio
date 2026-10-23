#pragma once
#include "ObsRuntime.h"
#include "StateStore.h"
#include <map>
#include <mutex>
#include <string>

/// Codificadores de Program partilhados (encode-once, D11) e saídas RTMP/SRT/gravação da libobs.
class Outputs {
public:
    Outputs(StateStore &store, ObsRuntime &rt) : store_(store), rt_(rt) {}
    void shutdown();

    std::string add(const std::string &kind, const std::string &name, const json &config, std::string &error);
    bool update(const std::string &id, const json &p);
    bool remove(const std::string &id, std::string &error);
    bool start(const std::string &id, std::string &error);
    bool stop(const std::string &id);
    bool startRecording(std::string &error);
    void stopRecording();
    bool anyActive();
    bool setStreamBus(int mixerIdx, std::string &error); // 0 Master, 1 A, 2 B; só com saídas paradas
    void setNdiBus(int mixerIdx);
    bool applyEncodingChange(std::string &error);       // descarta os codificadores para serem recriados com o estado novo                       // aplica em directo às saídas NDI
    void setNdiAvailable(bool on) { ndiAvailable_ = on; }

private:
    struct Entry { std::string kind, url, key, ndiName; int latencyMs = 120; obs_output_t *output = nullptr; obs_service_t *service = nullptr; };
    bool ensureEncoders();
    void releaseEncodersIfIdle();
    void setStatus(const std::string &id, const std::string &status, const std::string &code = "");
    static void onStart(void *, calldata_t *);
    static void onStop(void *, calldata_t *);
    static void onReconnect(void *, calldata_t *);
    static void onReconnectOk(void *, calldata_t *);
    struct SignalCtx { Outputs *self; std::string id; };

    StateStore &store_;
    ObsRuntime &rt_;
    std::mutex m_;
    std::map<std::string, Entry> outputs_;
    std::map<std::string, SignalCtx *> ctx_;
    obs_encoder_t *video_ = nullptr, *audio_ = nullptr;
    obs_output_t *rec_ = nullptr;
    int mixerIdx_ = 0, ndiMixerIdx_ = 0;
    bool ndiAvailable_ = false;
};
