# Instalação e empacotamento

## Pré-requisitos (máquina de desenvolvimento)

- macOS 14 ou superior em Apple Silicon; Xcode 26 (Swift 6.3). O Metal Toolchain não é necessário: os shaders compilam em execução.
- Node 22 ou superior.
- ffmpeg (Homebrew) só para testes; nunca é ligado ao produto.
- Opcional: runtime NDI (NDI Tools ou NDI Runtime). O motor procura `libndi.dylib` em `$NDI_RUNTIME_DIR_V6`, `/usr/local/lib`, `/Library/NDI SDK for Apple/lib/macOS` e dentro do plugin DAL do NDI Tools. Sem NDI, a saída NDI fica indisponível e tudo o resto funciona.

## Construir

```bash
npm install
npm run studio:build
engine/scripts/make-app-bundle.sh release
```

O script compila o motor em release, monta `engine/dist/WTV Engine.app` (com a interface em `Contents/Resources/ui`), aplica as entitlements de câmara, microfone e carregamento de bibliotecas externas, e assina ad-hoc (ou com a identidade passada como segundo argumento, por exemplo `"Developer ID Application: WayTV"`).

## Empacotar a aplicação

```bash
cd apps/studio && npx electron-builder --mac --arm64 --dir
```

Resultado: `release/mac-arm64/WTV Studio.app`, com o motor em `Contents/Helpers/WTV Engine.app`. Para um `.dmg`, troque `--dir` por `--mac dmg` (exige identidade de assinatura e notarização para distribuição fora da máquina).

## Como arranca

1. `WTV Studio.app` lê `~/Library/Application Support/WTV Studio/engine.json`. Se existir um motor vivo, liga-se a ele.
2. Caso contrário lança `WTV Engine.app` via LaunchServices (`open -g -n -a`). O motor fica filho do `launchd`, com identidade própria para o TCC (pedidos de câmara, microfone e ecrã aparecem em nome de "WTV Engine") e sobrevive ao fecho da interface.
3. O motor gera um token de 32 bytes, escreve `engine.json` (modo 0600) e serve a interface em `http://127.0.0.1:7420/`. A janela do Electron carrega esse endereço com `?token=…`; a interface troca o token por um cookie `HttpOnly` em `POST /api/session`.
4. Registo do motor em `~/Library/Logs/WTV Studio/engine.log` (roda aos 20 MB). Sessão em `session.json`; chaves de stream em `secrets.json` (0600).

## Permissões

- Câmara e microfone: pedidas pelo motor na primeira utilização.
- Gravação de ecrã: conceder a "WTV Engine" em Definições do Sistema → Privacidade e Segurança → Gravação de Ecrã.
- Volumes amovíveis: o motor não precisa de ler o disco externo. A interface e os dados vivem no disco interno. Se um ficheiro de vídeo estiver num disco externo, o macOS pede a permissão "Ficheiros e Pastas → Volumes amovíveis" para o WTV Engine.

## Desenvolvimento

```bash
npm run engine:run          # motor em modo --dev (sem token) em 127.0.0.1:7420
npm run studio:dev          # Electron com a UI do Vite
```

Ou, sem Electron, abra `http://127.0.0.1:7420/` num browser depois de lançar o motor com `--ui apps/studio/out/renderer`.

## NDI, SRT e plugins

- **NDI**: com o runtime presente, as fontes da rede aparecem em Fontes → "📡 nome" (botão ⟳ para procurar). A saída NDI anuncia-se com o nome escolhido. A libnd i é carregada dinamicamente; sem runtime, estas opções ficam indisponíveis sem afectar o resto.
- **SRT**: entrada e saída aceitam `srt://host:porta` (caller) ou `srt://:porta` (listener), com latência e passphrase. Para testar na mesma máquina: entrada `srt://:9000` e saída `srt://127.0.0.1:9000`.
- **Plugins Audio Unit**: no Audio Mixer, cada canal tem "+ plugin…" com todos os efeitos AU instalados no Mac (Apple e de terceiros). O botão ⚙ abre a janela do plugin (vista própria ou genérica), a chip com o nome liga/desliga (bypass) e × remove. Os plugins são instanciados no motor; a janela aparece como janela do WTV Engine.
- **Barramentos**: cada canal envia para Master, A e/ou B (botões M/A/B). Os auscultadores ouvem o barramento escolhido em "Monitorização"; "Barramento das saídas" escolhe o que vai para stream/gravação e para a NDI.

## Motor sobre a libobs (D23, em migração)

A compilação do OBS Studio faz-se **no disco interno** (o exFAT não aceita os atributos que o extractor das dependências escreve):

```bash
brew install cmake ninja
mkdir -p ~/.cache/wtv-obs && cd ~/.cache/wtv-obs
git clone --depth 1 --branch 32.0.1 https://github.com/obsproject/obs-studio.git
cd obs-studio && git submodule update --init --depth 1 plugins/obs-browser plugins/obs-websocket
printf 'enable_language(Swift)\n' > ../enable-swift.cmake
cmake --preset macos -B ../build -DENABLE_UI=OFF -DENABLE_BROWSER=OFF -DENABLE_SCRIPTING=OFF -DENABLE_VLC=OFF -DENABLE_VIRTUALCAM=OFF -DENABLE_SPARKLE=OFF -DENABLE_WEBSOCKET=OFF -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_COMPILE_WARNING_AS_ERROR=OFF -DCMAKE_PROJECT_INCLUDE=$HOME/.cache/wtv-obs/enable-swift.cmake
cmake --build ../build --config RelWithDebInfo --parallel 6
```

Notas desta máquina (Xcode 26.5, Swift 6.3): o renderer Metal (`libobs-metal`, em Swift) precisa de `@preconcurrency import AppKit` / `QuartzCore` em `MetalDevice.swift`, e o clang novo transforma avisos em erros no `mac-videotoolbox`, daí `CMAKE_COMPILE_WARNING_AS_ERROR=OFF`. O CMake do OBS exige os submódulos `obs-browser` e `obs-websocket` presentes mesmo desligados.

Prova de conceito (`engine-obs/poc`): arranca a libobs, cena com cor + texto, VideoToolbox H.264 + AAC, grava via `ffmpeg_muxer`:

```bash
cmake -S engine-obs/poc -B ~/.cache/wtv-obs/poc-build -G Ninja && cmake --build ~/.cache/wtv-obs/poc-build
```

Execução (as bibliotecas do obs-deps e a framework `libobs` resolvem-se por `@rpath`; o `obs-ffmpeg-mux` tem de estar ao lado do executável):

```bash
cd ~/.cache/wtv-obs && mkdir -p plugins && for p in build/plugins/*/RelWithDebInfo/*.plugin; do ln -sfn "$PWD/$p" "plugins/$(basename "$p")"; done
ln -sf ~/.cache/wtv-obs/build/plugins/obs-ffmpeg/ffmpeg-mux/RelWithDebInfo/obs-ffmpeg-mux ~/.cache/wtv-obs/poc-build/
DYLD_FRAMEWORK_PATH=~/.cache/wtv-obs/build/libobs/RelWithDebInfo DYLD_LIBRARY_PATH=~/.cache/wtv-obs/obs-studio/.deps/obs-deps-2025-08-23-universal/lib ~/.cache/wtv-obs/poc-build/wtv-poc ~/.cache/wtv-obs/plugins ~/.cache/wtv-obs/obs-studio/libobs/data /tmp/poc.mp4 5 ~/.cache/wtv-obs/build/libobs-metal/RelWithDebInfo/libobs-metal.dylib
```

Resultado verificado nesta máquina (2026-10-23): 1080p50 H.264 (`com.apple.videotoolbox.videoencoder.ave.avc`) + AAC (CoreAudio), 251 frames em 5 s sem frames perdidos com OpenGL; Metal também grava (6 frames atrasados no arranque). Pendente: o processo ainda termina com SIGSEGV na thread de tarefas da libobs durante `obs_shutdown`, mesmo com `obs_wait_for_destroy_queue()`; não afecta o ficheiro gravado.

## Empacotar o motor libobs (WTV Engine.app) e a app

```bash
npm run studio:build                       # UI em apps/studio/out/renderer
cmake --build ~/.cache/wtv-obs/engine-build
engine-obs/scripts/make-app-bundle.sh      # → engine-obs/dist/WTV Engine.app (assinatura ad-hoc; CODESIGN_IDENT=… para Developer ID)
cd apps/studio && npx electron-builder --mac --arm64 --dir   # → release/mac-arm64/WTV Studio.app com o motor em Contents/Helpers
```

O bundle leva `libobs.framework`, os renderers OpenGL e Metal, as dylibs do obs-deps, os plugins em `Contents/PlugIns`
(a libobs adiciona esse caminho sozinha dentro de um .app: o motor não o adiciona outra vez, senão cada plugin era carregado
duas vezes), `obs-ffmpeg-mux` ao lado do executável, a UI em `Contents/Resources/ui` e os efeitos em `Contents/Resources/obs-data`.
O script apaga as rpaths de desenvolvimento do executável e os ficheiros `._*` que o codesign volta a criar no exFAT.
No exFAT o `du` mostra ~1,1 GB por causa dos clusters de 1 MB; o conteúdo real anda nos 250 MB.

Sem `--dev` o motor gera um token novo, escreve `~/Library/Application Support/WTV Studio/engine.json` (0600) com
`{pid, port, token, version, startedAt}`, regista em `~/Library/Logs/WTV Studio/engine-obs.log` e exige sessão:
`POST /api/session {token}` devolve o cookie `wtv_session` (HttpOnly, SameSite=Strict); os WebSockets aceitam cookie,
`?token=` ou `Authorization: Bearer`, e recusam `Origin` que não seja a própria UI ou o Vite de desenvolvimento.
O Electron espera até 60 s pelo `engine.json` porque a libobs demora 10–20 s a carregar módulos e shaders.
Verificado nesta máquina (2026-10-23): a app lança o motor pelo LaunchServices (pai `launchd`), abre sessão e liga o preview.
