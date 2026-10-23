# Replay Source (vendorizado)

- Origem: https://github.com/exeldro/obs-replay-source (Exeldro)
- Versão: 1.8.1, commit `842a48eaf74fdaa2a3236ba30c42cf574359970f` (clonado em `~/.cache/wtv-obs/ext/obs-replay-source`)
- Licença: GPL-2.0 (ficheiro `LICENSE`; os ficheiros fonte do upstream não trazem cabeçalho por ficheiro)
- Ficheiros copiados sem alterações: `replay.c`, `replay.h`, `replay-source.c`, `replay-filter.c`,
  `replay-filter-async.c`, `replay-filter-audio.c`, `version.h.in`, `LICENSE`, `data/locale/en-US.ini`
  (o upstream não tem pt-PT nem pt-BR). Não foram copiados `win-dshow-replay.cpp` (só Windows) nem o installer.

## Alterações feitas para o motor WTV

- `version.h`: gerado a partir de `version.h.in` com a versão 1.8.1 (o upstream gera-o no CMake).
- `CMakeLists.txt`: substituído por um projecto autónomo que compila contra a `libobs.framework` do build
  do OBS 32.0.1 em `~/.cache/wtv-obs` e produz o bundle `replay-source.plugin` (Contents/MacOS, Resources/locale,
  Info.plist com `CFBundleIdentifier` `com.exeldro.replay-source`).
- `stub/obs-frontend-api.h` + `stub/stub.c`: o plugin usa só `obs_frontend_get_current_scene()` e
  `obs_frontend_set_current_scene()` da frontend-api (que no OBS Studio dependem da UI Qt). No motor WTV
  não há UI Qt: a primeira devolve `NULL` e a segunda não faz nada, pelo que as opções "Next Scene" e
  "Load switch scene" do plugin ficam sem efeito (a troca de Program é feita pelo motor).
- `Info.plist.in`: Info.plist mínimo do bundle.
- Patch a `replay-filter.c` (`replay_filter_destroy`): as chamadas `gs_stagesurface_unmap/destroy` e `gs_texrender_destroy`
  ficam dentro de `obs_enter_graphics()`/`obs_leave_graphics()`. A libobs 32 destrói as fontes numa thread de tarefas
  sem contexto gráfico, pelo que sem isto a textura e a stagesurface do filtro síncrono ficavam por libertar em cada desarme.
- Sem outros patches ao código fonte (compila limpo com o clang do Xcode 26.5, avisos desligados como erros).
