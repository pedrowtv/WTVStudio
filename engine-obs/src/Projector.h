#pragma once
#include "StateStore.h"
#include <obs.h>
#include <functional>
#include <string>

/// Projector: janela AppKit com um obs_display que desenha o Program, o multiview ou uma fonte.
/// Nunca ecrã inteiro no ecrã principal (lição do motor Swift); Esc e Cmd+W fecham.
namespace Projector {
/// Corre o ciclo de eventos do AppKit no main thread; `engineBody` corre numa thread própria e, ao terminar, o ciclo pára.
int runMainLoop(const std::function<void()> &engineBody);
json displays();                                                    // devices.displays
/// source = nullptr → Program (textura principal). displayId "" → fecha.
void open(const std::string &displayId, obs_source_t *source, bool fullscreen, std::function<void()> onClosed);
void close();
bool isOpen();
}
