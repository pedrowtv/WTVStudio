#pragma once
#include <nlohmann/json.hpp>
#include <deque>
#include <functional>
#include <mutex>
#include <optional>

using json = nlohmann::json;

/// Estado do motor (EngineState do PROTOCOLO.md) com `rev` monótono e patches RFC 6902 por mutação (D5).
class StateStore {
public:
    using PatchListener = std::function<void(int fromRev, int toRev, const json &ops)>;

    explicit StateStore(json initial);
    json snapshot();                                   // {"rev", "state"}
    json state();                                      // cópia do estado
    void mutate(const std::function<void(json &)> &fn); // aplica, calcula diff, notifica
    std::optional<json> patchesSince(int rev);         // nullopt → cliente deve pedir snapshot
    void setListener(PatchListener l) { listener_ = std::move(l); }
    int rev();

private:
    std::mutex m_;
    json state_;
    int rev_ = 0;
    std::deque<std::pair<int, json>> history_; // (toRev, ops)
    PatchListener listener_;
};

json defaultState(const std::string &engineVersion, const std::string &bind);
json defaultAudioChannel();
json multiviewTiles(const std::string &layoutId, const json &inputOrder, const json &inputs);
void refreshMultiview(json &s);
