/* Stub da obs-frontend-api para o motor WTV: o plugin só usa estas duas funções
 * (next_scene / load_switch_scene), que no OBS Studio dependem da janela Qt. */
#include "obs-frontend-api.h"

obs_source_t *obs_frontend_get_current_scene(void)
{
	return NULL;
}

void obs_frontend_set_current_scene(obs_source_t *scene)
{
	(void)scene;
}
