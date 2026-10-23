#pragma once
#include "StateStore.h"
#include "Switcher.h"
#include <obs.h>
#include <condition_variable>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <vector>

/// Replay instantâneo sobre o plugin Replay Source (Exeldro, GPL-2): cada ângulo armado tem um filtro de buffer
/// (replay_filter_async para fontes assíncronas — ffmpeg, câmaras, NDI — ou replay_filter para fontes síncronas) com
/// `bufferSeconds` de frames crus em RAM; o input "Replay" é uma replay_source pública que recebe o lance capturado
/// (os frames são MOVIDOS do buffer do ângulo para a replay_source) e toca-o à velocidade pedida.
///
/// Nomes: a replay_source resolve o filtro pelo NOME (um filtro com o nome da própria replay_source, na fonte indicada
/// em `source`) e, ao mudar de `source`, remove da fonte anterior todos os filtros com esse nome; se não encontrar
/// nenhum, cria um filtro próprio. Para manter N ângulos em buffer com uma só replay_source, os filtros vivem com o
/// nome do próprio ângulo (= inputId, fonte pública, o que satisfaz o replay_filter_check do plugin) e só o filtro do
/// ângulo a capturar é renomeado para o nome da replay_source durante o Load (ângulo "ligado"); o anterior volta ao nome
/// do ângulo. Ao desarmar o ângulo ligado, `source` é esvaziado primeiro para o plugin não criar um filtro órfão.
/// Todas as fontes obs do Switcher têm nome = inputId (único). Os dois filtros também capturam o áudio da fonte-mãe
/// (filter_audio), pelo que não é preciso replay_filter_audio.
class Replay {
public:
    static constexpr double MEMORY_BUDGET_MB = 2500; // Mac mini de 8 GB: resto para o sistema, codificadores e UI

    Replay(StateStore &store, Switcher &sw) : store_(store), sw_(sw) {}
    /// Detecta o plugin (status "unavailable" se não carregou) e activa o encaminhamento de hotkeys da libobs.
    void init();
    void shutdown(); // liberta os filtros antes de o Switcher destruir as fontes
    bool available() const { return available_; }
    std::string replayInputId();

    /// Liga ao input "Replay" acabado de criar pelo Switcher (kind "replay"): sinais, hotkeys e definições iniciais.
    void attachReplayInput(const std::string &inputId);
    /// Estimativa de RAM (MB) para `bufferSeconds` nos ângulos dados: buffers + até 2 lances guardados (replays=2).
    double estimateMemoryMB(int bufferSeconds, const std::vector<std::string> &angles);
    /// Arma/desarma ângulos e aplica a duração. Devolve o código de erro ("" = OK) e a mensagem.
    std::string setup(int bufferSeconds, const std::vector<std::string> &angles, std::string &message);
    /// Carrega o lance do ângulo (últimos `bufferSeconds`) na replay_source e começa a reproduzi-lo.
    std::string capture(const std::string &angleId, std::string &message);
    void setSpeed(double percent); // 1..400, sem salto de posição
    void pause(bool on);
    void restart();
    void next();
    void previous();
    void clear();
    /// Antes do take para Program: recomeça o lance do 1.º frame.
    void prepareOnAir();
    /// Chamado antes de o Switcher destruir a fonte: ângulo → sai de `angles`; input Replay → desarma tudo.
    void onInputRemoved(const std::string &inputId);

private:
    struct Angle { obs_source_t *filter = nullptr; bool async = false; bool hasAudio = false; };
    bool armAngle(const std::string &id, int durationMs, std::string &message);
    void disarmAngle(const std::string &id);
    void unlinkAngle(); // o filtro ligado volta ao nome do ângulo e a replay_source esquece `source`
    void detachReplayInput();
    bool triggerHotkey(const char *name);
    bool waitForUpdate(obs_data_t *settings); // obs_source_update + espera por um update diferido posterior ao apply
    bool waitForSignal();
    size_t bufferedFrames(obs_source_t *filter);
    void syncState(const std::function<void(json &)> &extra = nullptr);
    static void onSourceUpdate(void *data, calldata_t *);

    StateStore &store_;
    Switcher &sw_;
    std::mutex m_;
    bool available_ = false;
    std::string replayId_;
    obs_source_t *replay_ = nullptr; // sem retain (pertence ao Switcher)
    std::map<std::string, Angle> angles_;
    std::vector<std::string> order_; // ângulos pela ordem pedida em replay.setup
    std::string linkedAngle_;        // ângulo cujo filtro tem o nome da replay_source neste momento (= `source` do plugin)
    std::string clipAngle_;          // ângulo do lance carregado (estado replay.loadedAngle)
    bool loaded_ = false;            // há um lance na replay_source
    bool paused_ = false;            // intenção de pausa do realizador (o play_pause do plugin é um toggle)
    int bufferSeconds_ = 8;
    std::map<std::string, obs_hotkey_id> hotkeys_;
    std::mutex updM_;
    std::condition_variable updCv_;
    bool updated_ = false;
};
