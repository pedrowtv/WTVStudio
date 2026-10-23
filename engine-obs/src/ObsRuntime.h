#pragma once
#include <obs.h>
#include <string>

/// Arranque e paragem da libobs: vídeo, áudio, módulos (D23).
struct ObsConfig {
    std::string pluginsDir;   // directório com *.plugin
    std::string dataDir;      // libobs/data (efeitos)
    std::string graphicsModule; // caminho completo do libobs-opengl.dylib / libobs-metal.dylib
    int width = 1920, height = 1080;
    int fpsNum = 50, fpsDen = 1;
};

class ObsRuntime {
public:
    bool start(const ObsConfig &cfg);
    bool resetVideo(int width, int height, int fpsNum, int fpsDen);
    void stop();
    const ObsConfig &config() const { return cfg_; }
    std::string videoEncoderId() const; // VideoToolbox H.264 se existir, senão x264
private:
    ObsConfig cfg_;
    bool started_ = false;
};
