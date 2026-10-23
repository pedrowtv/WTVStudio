#pragma once
#include "StateStore.h"
#include <civetweb.h>
#include <cstdint>
#include <functional>
#include <mutex>
#include <set>
#include <string>
#include <vector>

/// HTTP + WebSocket (civetweb): serve a UI estática, /api/session, /ws/control (JSON-RPC) e /ws/preview (binário WTVF).
class ControlServer {
public:
    using Handler = std::function<json(const json &request)>;
    struct Config { std::string bind = "127.0.0.1"; int port = 7420; std::string uiDir; bool dev = true; std::string token; /* vazio = --dev */ };

    bool start(const Config &cfg, Handler handler);
    void stop();
    void broadcastControl(const json &message);
    void sendPreview(bool keyframe, const std::vector<uint8_t> &avcC, const uint8_t *au, size_t len, uint64_t ptsMicros);
    bool hasPreviewClients();
    void sendMeters(const std::vector<uint8_t> &payload); // streamId 16 a todos os clientes de preview

private:
    static int wsConnect(const mg_connection *, void *);
    static void wsReady(mg_connection *, void *);
    static int wsControlData(mg_connection *, int bits, char *data, size_t len, void *);
    static int wsPreviewData(mg_connection *, int, char *, size_t, void *);
    static void wsClose(const mg_connection *, void *);
    static int apiSession(mg_connection *, void *);
    static int apiHealth(mg_connection *, void *);
    void writeText(mg_connection *c, const std::string &s);
    bool authorised(const mg_connection *c);   // cookie de sessão, token na query ou Bearer (D21)
    bool originAllowed(const mg_connection *c);
    static bool constantEquals(const std::string &a, const std::string &b);
    std::set<std::string> sessions_;

    struct PreviewClient { mg_connection *conn; bool waitingKey = true; };
    Config cfg_;
    Handler handler_;
    mg_context *ctx_ = nullptr;
    std::mutex m_;
    std::set<mg_connection *> control_;
    std::vector<PreviewClient> preview_;
    uint32_t seq_ = 0;
};
