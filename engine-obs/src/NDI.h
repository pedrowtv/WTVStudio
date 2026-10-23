#pragma once
#include "StateStore.h"
#include <obs.h>
#include <string>

/// NDI sobre o shim CNDI (libndi carregada por dlopen; D17): fonte "wtv_ndi_source" (vídeo BGRA assíncrono
/// + áudio float planar), saída "wtv_ndi_output" (raw BGRA + áudio) e descoberta de fontes na rede.
namespace NDI {
bool load();                       // tenta carregar a libndi; false → sem NDI (capabilities.ndi = false)
bool available();
std::string version();
void registerTypes();              // regista a fonte e a saída na libobs (depois de load())
json discover(unsigned waitMs);    // devices.ndiSources: [{name, url}]
void shutdown();
}
