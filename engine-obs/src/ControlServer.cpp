#include "ControlServer.h"
#include <cstring>
#include <random>

struct WsTag { ControlServer *server; bool preview; };

bool ControlServer::start(const Config &cfg, Handler handler) {
    cfg_ = cfg; handler_ = std::move(handler);
    mg_init_library(0);
    std::string ports = cfg.bind + ":" + std::to_string(cfg.port);
    const char *options[] = {
        "listening_ports", ports.c_str(), "document_root", cfg.uiDir.c_str(), "num_threads", "12",
        "enable_directory_listing", "no", "websocket_timeout_ms", "86400000", "enable_keep_alive", "yes",
        "keep_alive_timeout_ms", "5000", "access_control_allow_origin", "*", nullptr};
    mg_callbacks cb{};
    ctx_ = mg_start(&cb, this, options);
    if (!ctx_) return false;
    static WsTag control{this, false}, preview{this, true};
    mg_set_websocket_handler(ctx_, "/ws/control", wsConnect, wsReady, wsControlData, wsClose, &control);
    mg_set_websocket_handler(ctx_, "/ws/preview", wsConnect, wsReady, wsPreviewData, wsClose, &preview);
    mg_set_request_handler(ctx_, "/api/session", apiSession, this);
    mg_set_request_handler(ctx_, "/api/health", apiHealth, this);
    return true;
}

void ControlServer::stop() {
    if (ctx_) { mg_stop(ctx_); ctx_ = nullptr; }
    mg_exit_library();
}

static int replyJson(mg_connection *c, const std::string &body) {
    mg_send_http_ok(c, "application/json", (long long)body.size());
    mg_write(c, body.data(), body.size());
    return 200;
}

static std::string randomHex(int bytes) {
    static std::random_device rd; std::string s;
    for (int i = 0; i < bytes; i++) { unsigned v = rd() & 0xFF; char b[3]; snprintf(b, sizeof b, "%02x", v); s += b; }
    return s;
}

bool ControlServer::constantEquals(const std::string &a, const std::string &b) {
    if (a.size() != b.size()) return false;
    unsigned char d = 0;
    for (size_t i = 0; i < a.size(); i++) d |= (unsigned char)(a[i] ^ b[i]);
    return d == 0;
}

static std::string cookieValue(const char *header, const std::string &name) {
    if (!header) return "";
    std::string h = header; size_t p = 0;
    while (p < h.size()) {
        size_t e = h.find(';', p); if (e == std::string::npos) e = h.size();
        std::string part = h.substr(p, e - p);
        size_t s = part.find_first_not_of(' '); if (s != std::string::npos) part = part.substr(s);
        if (part.rfind(name + "=", 0) == 0) return part.substr(name.size() + 1);
        p = e + 1;
    }
    return "";
}

static std::string queryValue(const char *qs, const std::string &key) {
    if (!qs) return "";
    char buf[256];
    int n = mg_get_var(qs, strlen(qs), key.c_str(), buf, sizeof buf);
    return n > 0 ? std::string(buf, n) : "";
}

int ControlServer::apiSession(mg_connection *c, void *p) {
    auto *self = static_cast<ControlServer *>(p);
    if (self->cfg_.token.empty()) return replyJson(c, R"({"ok":true,"dev":true})");
    char body[1024] = {0};
    int n = mg_read(c, body, sizeof body - 1);
    std::string given;
    if (n > 0) { json j = json::parse(std::string(body, n), nullptr, false); if (j.is_object()) given = j.value("token", ""); }
    if (given.empty()) { const char *auth = mg_get_header(c, "Authorization"); if (auth && strncmp(auth, "Bearer ", 7) == 0) given = auth + 7; }
    if (!constantEquals(given, self->cfg_.token)) { mg_send_http_error(c, 401, "token inválido"); return 401; }
    std::string sid = randomHex(16);
    { std::lock_guard l(self->m_); self->sessions_.insert(sid); }
    fprintf(stderr, "sessão criada por %s\n", mg_get_header(c, "User-Agent") ? mg_get_header(c, "User-Agent") : "?");
    std::string resp = R"({"ok":true})";
    mg_printf(c, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %zu\r\nSet-Cookie: wtv_session=%s; Path=/; HttpOnly; SameSite=Strict\r\nConnection: close\r\n\r\n%s", resp.size(), sid.c_str(), resp.c_str());
    return 200;
}

bool ControlServer::authorised(const mg_connection *c) {
    if (cfg_.token.empty()) return true;
    const mg_request_info *ri = mg_get_request_info(c);
    std::string sid = cookieValue(mg_get_header(c, "Cookie"), "wtv_session");
    if (!sid.empty()) { std::lock_guard l(m_); if (sessions_.count(sid)) return true; }
    std::string q = queryValue(ri->query_string, "token");
    if (!q.empty() && constantEquals(q, cfg_.token)) return true;
    const char *auth = mg_get_header(c, "Authorization");
    if (auth && strncmp(auth, "Bearer ", 7) == 0 && constantEquals(auth + 7, cfg_.token)) return true;
    return false;
}

bool ControlServer::originAllowed(const mg_connection *c) {
    const char *origin = mg_get_header(c, "Origin");
    if (!origin || !*origin) return true; // clientes não-browser
    std::string o = origin, port = std::to_string(cfg_.port);
    return o == "http://127.0.0.1:" + port || o == "http://localhost:" + port || o == "http://localhost:5173" || o == "null";
}
int ControlServer::apiHealth(mg_connection *c, void *) { return replyJson(c, R"({"ok":true})"); }

int ControlServer::wsConnect(const mg_connection *c, void *tag) {
    auto *self = static_cast<WsTag *>(tag)->server;
    if (!self->originAllowed(c)) { fprintf(stderr, "upgrade recusado: Origin %s\n", mg_get_header(c, "Origin")); return 1; }
    if (!self->authorised(c)) { fprintf(stderr, "upgrade recusado: sem sessão válida\n"); return 1; }
    return 0;
}

void ControlServer::wsReady(mg_connection *c, void *tag) {
    auto *t = static_cast<WsTag *>(tag);
    std::lock_guard l(t->server->m_);
    if (t->preview) t->server->preview_.push_back({c, true});
    else t->server->control_.insert(c);
}

void ControlServer::wsClose(const mg_connection *c, void *tag) {
    auto *t = static_cast<WsTag *>(tag);
    std::lock_guard l(t->server->m_);
    t->server->control_.erase(const_cast<mg_connection *>(c));
    auto &v = t->server->preview_;
    for (size_t i = 0; i < v.size(); i++) if (v[i].conn == c) { v.erase(v.begin() + i); break; }
}

void ControlServer::writeText(mg_connection *c, const std::string &s) {
    mg_lock_connection(c);
    mg_websocket_write(c, MG_WEBSOCKET_OPCODE_TEXT, s.data(), s.size());
    mg_unlock_connection(c);
}

int ControlServer::wsControlData(mg_connection *c, int bits, char *data, size_t len, void *tag) {
    auto *self = static_cast<WsTag *>(tag)->server;
    int op = bits & 0xF;
    if (op == MG_WEBSOCKET_OPCODE_CONNECTION_CLOSE) return 0;
    if (op != MG_WEBSOCKET_OPCODE_TEXT) return 1;
    json req = json::parse(std::string(data, len), nullptr, false);
    json res;
    if (req.is_discarded()) res = {{"jsonrpc", "2.0"}, {"id", nullptr}, {"error", {{"code", -32700}, {"message", "JSON inválido"}}}};
    else res = self->handler_(req);
    if (!res.is_null()) self->writeText(c, res.dump());
    return 1;
}

int ControlServer::wsPreviewData(mg_connection *, int bits, char *, size_t, void *) {
    return (bits & 0xF) == MG_WEBSOCKET_OPCODE_CONNECTION_CLOSE ? 0 : 1;
}

void ControlServer::broadcastControl(const json &message) {
    std::string s = message.dump();
    std::lock_guard l(m_);
    for (auto *c : control_) writeText(c, s);
}

bool ControlServer::hasPreviewClients() { std::lock_guard l(m_); return !preview_.empty(); }

void ControlServer::sendPreview(bool key, const std::vector<uint8_t> &avcC, const uint8_t *au, size_t len, uint64_t pts) {
    std::lock_guard l(m_);
    if (preview_.empty()) return;
    bool withConfig = key && !avcC.empty();
    uint32_t payloadLen = (uint32_t)(len + (withConfig ? 2 + avcC.size() : 0));
    std::vector<uint8_t> buf(24 + payloadLen);
    uint8_t *h = buf.data();
    memcpy(h, "WTVF", 4);
    h[4] = 1; h[5] = 1; h[6] = (key ? 1 : 0) | (withConfig ? 2 : 0); h[7] = 1; // version, streamId multiview, flags, codec avc1
    uint32_t seq = seq_++;
    memcpy(h + 8, &seq, 4); memcpy(h + 12, &pts, 8); memcpy(h + 20, &payloadLen, 4);
    size_t off = 24;
    if (withConfig) { uint16_t n = (uint16_t)avcC.size(); memcpy(h + off, &n, 2); off += 2; memcpy(h + off, avcC.data(), n); off += n; }
    memcpy(h + off, au, len);
    for (auto &pc : preview_) {
        if (pc.waitingKey && !key) continue;
        pc.waitingKey = false;
        mg_lock_connection(pc.conn);
        mg_websocket_write(pc.conn, MG_WEBSOCKET_OPCODE_BINARY, (const char *)buf.data(), buf.size());
        mg_unlock_connection(pc.conn);
    }
}

void ControlServer::sendMeters(const std::vector<uint8_t> &payload) {
    std::lock_guard l(m_);
    if (preview_.empty()) return;
    std::vector<uint8_t> buf(24 + payload.size());
    uint8_t *h = buf.data();
    memcpy(h, "WTVF", 4);
    h[4] = 1; h[5] = 16; h[6] = 0; h[7] = 0;
    uint32_t seq = seq_++, len = (uint32_t)payload.size(); uint64_t pts = 0;
    memcpy(h + 8, &seq, 4); memcpy(h + 12, &pts, 8); memcpy(h + 20, &len, 4);
    memcpy(h + 24, payload.data(), payload.size());
    for (auto &pc : preview_) { mg_lock_connection(pc.conn); mg_websocket_write(pc.conn, MG_WEBSOCKET_OPCODE_BINARY, (const char *)buf.data(), buf.size()); mg_unlock_connection(pc.conn); }
}
