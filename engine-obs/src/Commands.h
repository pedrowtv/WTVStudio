#pragma once
#include "ObsRuntime.h"
#include "StateStore.h"
#include "Switcher.h"
#include "Outputs.h"
#include "AudioEngine.h"
#include <atomic>
#include <string>

/// Despacho JSON-RPC 2.0 (métodos do PROTOCOLO.md) sobre o StateStore e o Switcher.
class Commands {
public:
    Commands(StateStore &store, Switcher &sw, ObsRuntime &rt, Outputs &out, AudioEngine &audio, std::string engineVersion);
    json handle(const json &req);
    void onTransitionDone();
    void onMediaEnded(const std::string &inputId); // playlist: passa ao item seguinte     // troca Preview/Program no estado quando a libobs termina a transição
    void tickMedia();            // actualiza posições/estado de media (chamar ~2×/s)
    std::atomic<bool> shutdownRequested{false};

private:
    json dispatch(const std::string &method, const json &p);
    std::string requireInput(const json &p);
    void syncMultiview();

    StateStore &store_;
    Switcher &sw_;
    ObsRuntime &rt_;
    Outputs &out_;
    AudioEngine &audio_;
    void applyAudio(const std::string &inputId = ""); // "" = todos os canais
    std::string version_;
};

struct RpcError { std::string code; std::string message; };
