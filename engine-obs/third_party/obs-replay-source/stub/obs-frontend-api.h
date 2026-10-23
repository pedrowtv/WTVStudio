/* Stub da obs-frontend-api para o motor WTV (sem UI Qt).
 * Só as declarações que o replay-source.c usa; implementação em stub.c. */
#pragma once

#include <obs.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Devolve sempre NULL: o motor não tem "cena actual" no sentido do OBS Studio. */
obs_source_t *obs_frontend_get_current_scene(void);
/* Não faz nada: a troca de cena/Program é feita pelo motor (Switcher), não pelo plugin. */
void obs_frontend_set_current_scene(obs_source_t *scene);

#ifdef __cplusplus
}
#endif
