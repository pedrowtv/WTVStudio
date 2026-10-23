#pragma once
#include "ObsRuntime.h"
#include "StateStore.h"
#include "Switcher.h"
#include <atomic>
#include <string>

/// Despacho JSON-RPC 2.0 (métodos do PROTOCOLO.md) sobre o StateStore e o Switcher.
class Commands {
public:
    Commands(StateStore &store, Switcher &sw, ObsRuntime &rt, std::string engineVersion);
    json handle(const json &req);
    void onTransitionDone();     // troca Preview/Program no estado quando a libobs termina a transição
    void tickMedia();            // actualiza posições/estado de media (chamar ~2×/s)
    std::atomic<bool> shutdownRequested{false};

private:
    json dispatch(const std::string &method, const json &p);
    std::string requireInput(const json &p);
    void syncMultiview();
    bool startRecording(std::string &error);
    void stopRecording();

    StateStore &store_;
    Switcher &sw_;
    ObsRuntime &rt_;
    std::string version_;
    std::mutex recM_;
    obs_output_t *recOutput_ = nullptr;
    obs_encoder_t *recVideo_ = nullptr, *recAudio_ = nullptr;
};

struct RpcError { std::string code; std::string message; };
