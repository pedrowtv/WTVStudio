#pragma once
#include "StateStore.h"
#include <obs.h>
#include <string>

/// Audio Units (v2) alojados como filtro de áudio da libobs ("wtv_au_filter", definição "component" = "au:tipo:subtipo:fabricante").
namespace AudioUnitHost {
void registerType();
json catalogue();                                       // efeitos aufx/aumf instalados → devices.audioUnits (id "au:...")
bool isAU(obs_source_t *filter);
json params(obs_source_t *filter);                       // {properties, values} com os parâmetros do AU
bool setParams(obs_source_t *filter, const json &params);
void openWindow(obs_source_t *filter, const std::string &title); // vista própria do plugin ou AUGenericView (main thread)
void closeWindow(obs_source_t *filter);
}
