#pragma once
#include "ObsRuntime.h"
#include "StateStore.h"
#include "AudioEngine.h"
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
    /// MultiCorder: grava uma fonte (vídeo da fonte + só o seu áudio) num ficheiro próprio, em paralelo com o Program.
    bool isoStart(const std::string &inputId, obs_source_t *source, const std::string &name, std::string &error);
    bool isoStop(const std::string &inputId);
    void isoStopAll();
    void setAudioEngine(AudioEngine *a) { audioEngine_ = a; }
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
    struct Iso { obs_scene_t *scene = nullptr; obs_view_t *view = nullptr; video_t *video = nullptr; obs_encoder_t *venc = nullptr, *aenc = nullptr; obs_output_t *out = nullptr; int track = -1; std::string file; };
    std::map<std::string, Iso> iso_;
    AudioEngine *audioEngine_ = nullptr;
    static void onIsoStop(void *, calldata_t *);
    void isoRelease(const std::string &id);
    int mixerIdx_ = 0, ndiMixerIdx_ = 0;
    bool ndiAvailable_ = false;
};
