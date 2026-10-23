// WTV Engine sobre a libobs (D23): arranque, servidor de controlo, switcher e preview multiview.
#include "Commands.h"
#include "ControlServer.h"
#include "ObsRuntime.h"
#include "Outputs.h"
#include "AudioEngine.h"
#include "NDI.h"
#include "Projector.h"
#include "PitchFilter.h"
#include "PreviewOutput.h"
#include "StateStore.h"
#include "Switcher.h"
#include <csignal>
#include <fstream>
#include <random>
#include <sys/stat.h>
#include <mach-o/dyld.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>
#include <thread>

static std::atomic<bool> g_stop{false};
static const char *ENGINE_VERSION = "0.2.0-libobs";

static std::string bundleContents() {
    char buf[4096]; uint32_t n = sizeof buf;
    if (_NSGetExecutablePath(buf, &n) != 0) return "";
    char real[PATH_MAX]; if (!realpath(buf, real)) return "";
    std::string p = real; size_t i = p.find("/Contents/MacOS/");
    return i == std::string::npos ? "" : p.substr(0, i + 9);
}

static std::string randomToken() {
    std::random_device rd; std::string s;
    for (int i = 0; i < 32; i++) { char b[3]; snprintf(b, sizeof b, "%02x", rd() & 0xFF); s += b; }
    return s;
}

static std::string isoNow() { char b[32]; time_t t = time(nullptr); strftime(b, sizeof b, "%Y-%m-%dT%H:%M:%SZ", gmtime(&t)); return b; }

int main(int argc, char **argv) {
    ObsConfig oc;
    ControlServer::Config sc;
    sc.dev = false;
    std::string home = getenv("HOME");
    std::string contents = bundleContents();
    if (!contents.empty()) { // dentro de WTV Engine.app
        oc.pluginsDir = ""; // a libobs usa Contents/PlugIns por omissão
        oc.dataDir = contents + "/Resources/obs-data";
        oc.graphicsModule = contents + "/Frameworks/libobs-metal.dylib";
        sc.uiDir = contents + "/Resources/ui";
    } else {
        oc.pluginsDir = home + "/.cache/wtv-obs/plugins";
        oc.dataDir = std::string(WTV_OBS_SRC_DIR) + "/libobs/data";
        oc.graphicsModule = std::string(WTV_OBS_BUILD_DIR) + "/libobs-metal/RelWithDebInfo/libobs-metal.dylib";
    }
    std::string dataDir = home + "/Library/Application Support/WTV Studio";
    mkdir(dataDir.c_str(), 0700);
    mkdir((home + "/Library/Logs/WTV Studio").c_str(), 0755);
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() -> std::string { return i + 1 < argc ? argv[++i] : ""; };
        if (a == "--port") sc.port = atoi(next().c_str());
        else if (a == "--bind") sc.bind = next();
        else if (a == "--ui") sc.uiDir = next();
        else if (a == "--plugins") oc.pluginsDir = next();
        else if (a == "--data") oc.dataDir = next();
        else if (a == "--graphics") oc.graphicsModule = next();
        else if (a == "--opengl") oc.graphicsModule = contents.empty() ? std::string(WTV_OBS_BUILD_DIR) + "/libobs-opengl/RelWithDebInfo/libobs-opengl.dylib" : contents + "/Frameworks/libobs-opengl.dylib";
        else if (a == "--dev") sc.dev = true;
        else { fprintf(stderr, "argumento desconhecido: %s\n", a.c_str()); return 2; }
    }
    if (sc.bind != "127.0.0.1" && sc.dev) { fprintf(stderr, "--dev só em loopback\n"); return 2; }
    if (!sc.dev) {
        sc.token = randomToken(); // token novo a cada arranque (D21)
        std::string logPath = home + "/Library/Logs/WTV Studio/engine-obs.log";
        if (!freopen(logPath.c_str(), "a", stderr)) perror("log");
        setvbuf(stderr, nullptr, _IOLBF, 0);
    }
    chdir(dataDir.c_str()); // a libobs (rtmp-services) escreve caches no directório corrente

    ObsRuntime rt;
    if (!rt.start(oc)) { fprintf(stderr, "libobs não arrancou\n"); return 1; }
    PreviewOutput::registerType();
    PitchFilter::registerType();
    NDI::load();
    NDI::registerTypes();

    Switcher sw;
    if (!sw.init(oc.width, oc.height, 1280, 720)) { fprintf(stderr, "switcher não inicializou\n"); return 1; }

    StateStore store(defaultState(ENGINE_VERSION, sc.bind + ":" + std::to_string(sc.port)));
    Outputs outputs(store, rt);
    outputs.setNdiAvailable(NDI::available());
    AudioEngine audio;
    audio.start();
    Commands cmd(store, sw, rt, outputs, audio, ENGINE_VERSION);
    sw.onTransitionDone = [&] { cmd.onTransitionDone(); };
    sw.onMediaEnded = [&](const std::string &id) { cmd.onMediaEnded(id); };

    ControlServer server;
    store.setListener([&](int from, int to, const json &ops) {
        server.broadcastControl({{"jsonrpc", "2.0"}, {"method", "state.patch"}, {"params", {{"fromRev", from}, {"toRev", to}, {"ops", ops}}}});
    });
    if (!server.start(sc, [&](const json &req) { return cmd.handle(req); })) { fprintf(stderr, "servidor não arrancou em %s:%d (porta ocupada?)\n", sc.bind.c_str(), sc.port); return 1; }
    std::string engineJson = dataDir + "/engine.json";
    if (!sc.dev) {
        json info = {{"pid", (int)getpid()}, {"port", sc.port}, {"token", sc.token}, {"version", ENGINE_VERSION}, {"startedAt", isoNow()}};
        std::ofstream f(engineJson, std::ios::trunc); f << info.dump(); f.close();
        chmod(engineJson.c_str(), 0600);
    }

    PreviewOutput preview;
    if (!preview.start(sw.multiviewVideo(), rt.videoEncoderId(), 4000,
                       [&](bool key, const std::vector<uint8_t> &avcC, const uint8_t *au, size_t len, uint64_t pts) { server.sendPreview(key, avcC, au, len, pts); })) {
        fprintf(stderr, "preview multiview não arrancou\n");
    }

    signal(SIGINT, [](int) { g_stop = true; });
    signal(SIGTERM, [](int) { g_stop = true; });
    fprintf(stderr, "WTV Engine %s em http://%s:%d (libobs %s, %s)\n", ENGINE_VERSION, sc.bind.c_str(), sc.port, obs_get_version_string(), rt.videoEncoderId().c_str());

    // O main thread fica com o ciclo do AppKit (projector); o motor corre numa thread própria.
    return Projector::runMainLoop([&] {
        int tick = 0;
        while (!g_stop && !cmd.shutdownRequested) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            if (++tick % 5 == 0) cmd.tickMedia();
            if (tick % 50 == 0 && NDI::available()) { json ndi = NDI::discover(0); store.mutate([&](json &s) { s["devices"]["ndiSources"] = ndi; }); }
            if (server.hasPreviewClients()) server.sendMeters(audio.metersFrame(store.state()["inputOrder"]));
        }
        fprintf(stderr, "a encerrar\n");
        if (!sc.dev) unlink(engineJson.c_str());
        Projector::close();
        preview.stop();
        outputs.shutdown();
        server.stop();
        audio.shutdown();
        NDI::shutdown();
        sw.shutdown();
        rt.stop();
    });
}
