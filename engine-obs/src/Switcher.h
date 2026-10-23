#pragma once
#include "StateStore.h"
#include <obs.h>
#include <functional>
#include <map>
#include <mutex>
#include <string>

/// Switcher Preview/Program por cima da libobs: o canal de saída 0 é sempre uma fonte de transição
/// (cut/fade/wipe/dip) cuja fonte actual é o Program; o Preview é uma referência de estado que a
/// cena multiview mostra directamente. Mantém o modelo de estado do PROTOCOLO.md.
class Switcher {
public:
    struct Media { double durationSeconds = 0, positionSeconds = 0; std::string state = "stopped"; };

    bool init(int baseW, int baseH, int mvW, int mvH);
    void shutdown();

    bool addInput(const std::string &id, const std::string &kind, const json &config, const std::string &name, int rasterW, int rasterH, std::string &error);
    void updateInput(const std::string &id, const std::string &kind, const json &config);
    void removeInput(const std::string &id);
    bool hasInput(const std::string &id);

    void cut(const std::string &programId);              // Program passa a ser `programId` sem animação
    bool transition(const std::string &kind, int durationMs, const json &params, const std::string &destId);
    void tbar(double pos, const std::string &destId, const std::string &programId);
    void ftb(bool on, const std::string &programId);
    void rebuildMultiview(const json &tiles, const std::string &previewId);
    /// Aplica um slot de overlay (1..4) do estado: fonte, rectângulo, opacidade e transição on/off.
    void setOverlay(int slot, const json &overlay, double fps);
    /// AFV desligado: a fonte entra na cena Program como item fora do ecrã (1×1 px) para ser sempre misturada no áudio.
    void setAlwaysAudible(const std::string &id, bool on);

    void setAudio(const std::string &id, double db, bool mute);
    void mediaCommand(const std::string &id, const std::string &cmd, const json &p);
    Media mediaInfo(const std::string &id);
    bool hasVideo(const std::string &id);
    obs_source_t *sourceRef(const std::string &id) { std::lock_guard l(m_); return source(id); } // sem retain: válido enquanto a fonte existir // largura > 0 → a fonte está a produzir imagem

    video_t *multiviewVideo() { return mvVideo_; }
    obs_source_t *multiviewSource() { return obs_scene_get_source(mvScene_); }
    std::function<void()> onTransitionDone; // chamado (na thread de vídeo) quando uma transição automática/manual termina

private:
    obs_source_t *source(const std::string &id);
    obs_source_t *transitionFor(const std::string &kind, const json &params);
    void swapTransition(obs_source_t *next);
    static void transitionStopped(void *data, calldata_t *);

    std::mutex m_;
    std::map<std::string, obs_source_t *> inputs_;
    std::map<std::string, obs_source_t *> transitions_;
    obs_source_t *current_ = nullptr; // transição Program (item de base da cena Program)
    obs_scene_t *programScene_ = nullptr; // canal 0: transição + overlays 1..4
    obs_sceneitem_t *programItem_ = nullptr;
    struct Overlay { obs_source_t *fade = nullptr; obs_scene_t *scene = nullptr; obs_source_t *opacity = nullptr; bool on = false; std::string inputId; };
    Overlay overlays_[4];
    std::map<std::string, obs_sceneitem_t *> audioItems_;
    obs_source_t *black_ = nullptr;
    obs_scene_t *mvScene_ = nullptr;
    obs_view_t *mvView_ = nullptr;
    video_t *mvVideo_ = nullptr;
    int baseW_ = 1920, baseH_ = 1080;
    bool pending_ = false; // transição em curso iniciada por `transition`/`tbar`
    bool ftb_ = false;
};
