# WTV Studio — Arquitectura

Documento de decisão. Resulta de quatro propostas independentes (entrega, desempenho, fiabilidade, integração) julgadas contra os factos medidos em [AMBIENTE.md](AMBIENTE.md). Onde as propostas divergiam, a escolha e o motivo estão registados na secção "Decisões".

Identificadores de código em inglês; texto em português europeu.

## 1. Objectivo

Um misturador de vídeo ao vivo tipo vMix para macOS Apple Silicon:

- Entradas: câmaras USB/UVC e Continuity Camera, placas de captura HDMI/SDI (UVC e Blackmagic DeckLink), NDI e SRT pela rede, ficheiros de vídeo/imagem/áudio, captura de ecrã, fontes sintéticas e títulos.
- Saídas: RTMP/RTMPS para N destinos, gravação local, saída NDI, projector em ecrã externo.
- Escala: 8 ou mais fontes a 1080p50/60 nesta máquina; 4K com limites honestos (ver §9).

## 2. Visão geral

Dois programas que cooperam:

| Programa | Tecnologia | Responsabilidade |
|---|---|---|
| **WTV Engine.app** | Swift 6.3, SwiftPM, AppKit (sem Dock, `LSUIElement`), Metal, AVFoundation, VideoToolbox, CoreAudio | Tudo o que toca em vídeo, áudio, dispositivos, codificadores, rede de emissão e projector. Serve HTTP + WebSocket em `127.0.0.1:7420`. Continua a emitir se a interface morrer. |
| **WTV Studio.app** | Electron 44.9 (Chromium 152), React 19, zustand 5, TypeScript, electron-vite 6 | Apenas superfície de controlo. O processo principal lança/encontra o motor, gere janelas e diálogos nativos. O renderer é uma aplicação web pura que fala com o motor por WebSocket. |

O mesmo bundle React é servido pelo motor em `http://<mac>.local:7420/`, por isso um browser na rede local (tablet, segundo operador) usa exactamente a mesma interface e o mesmo protocolo. Nenhuma funcionalidade essencial depende de APIs do Electron.

```
┌──────────────────────────────┐        ┌───────────────────────────────────────────────┐
│ WTV Studio.app (Electron)    │        │ WTV Engine.app (Swift)                        │
│  main: supervisor, janelas   │  open  │  ControlServer  HTTP+WS 127.0.0.1:7420        │
│  renderer: React (web puro)  │ ─────▶ │  StateStore (actor, rev + JSON Patch)         │
│    WebSocket ◀──────────────────────▶ │  VideoClock thread ─▶ Metal compositor        │
│    WebCodecs decode preview  │        │  AudioMixer thread (48 kHz)                   │
└──────────────────────────────┘        │  Inputs: AVF, SCK, files, synth, NDI, SRT, BMD│
┌──────────────────────────────┐        │  Encoder pool (VideoToolbox, encode-once)     │
│ Browser LAN (tablet)         │ ◀────▶ │  Outputs: RTMP(S), SRT, MOV/MP4, NDI, projector│
└──────────────────────────────┘        └───────────────────────────────────────────────┘
```

## 3. Decisões

Cada linha diz o que ficou decidido e porquê. As alternativas rejeitadas vêm das propostas.

| # | Decisão | Motivo |
|---|---|---|
| D1 | **Dois processos**, motor nativo separado da interface Electron. | Electron não aguenta 8 fontes/4K no caminho dos pixels; a emissão tem de sobreviver a crashes da UI. Unânime nas quatro propostas. |
| D2 | O motor é um **bundle .app** (`WTV Engine.app`) lançado por LaunchServices (`open -g -a`), não um filho `spawn` do Electron. | Um bundle lançado pelo `open` é o seu próprio "responsible process" para o TCC: os pedidos de câmara, microfone e ecrã mostram as strings do motor e as permissões persistem quando a UI sai. Um filho `spawn` seria atribuído ao Electron ou, em desenvolvimento, ao Terminal. |
| D3 | Servidor HTTP/WebSocket dentro do motor: **Hummingbird 2.x + hummingbird-websocket** (SwiftNIO, Apache-2.0). | Três propostas escolheram NIO; é maduro, serve ficheiros estáticos e WebSocket com backpressure. FlyingFox fica como alternativa se a dependência pesar. |
| D4 | **Dois WebSockets** por cliente: `/ws/control` (texto JSON) e `/ws/preview` (binário). | Backpressure do vídeo nunca atrasa comandos. Custo nulo. |
| D5 | Controlo em **JSON-RPC 2.0**; estado por **snapshot + JSON Patch (RFC 6902)** com `rev` monótono; telemetria rápida fora do estado. | Reconexão trivial (pede snapshot), UI é função pura do estado, diffs pequenos. Detalhe em [PROTOCOLO.md](PROTOCOLO.md). |
| D6 | **Relógio mestre = host clock** (`mach_absolute_time`), ticks racionais exactos (1001/60000, 1/50, 1/60) calculados a partir de N, nunca acumulados. Thread de vídeo com `THREAD_TIME_CONSTRAINT_POLICY` e `mach_wait_until`. | Zero deriva em 59.94; emissão headless não depende do refresh do ecrã. |
| D7 | Áudio: mixer float32 48 kHz numa thread própria de 10 ms (480 amostras), fontes em anéis SPSC lock-free; dispositivo de saída via IOProc da HAL. Fase 1 tolera deriva com inserção/remoção de amostras em fronteira de bloco; Fase 2 adiciona ASRC por fonte (controlador PI). | Mais simples que fazer o dispositivo USB (Volt 2) mestre de tudo; a deriva típica (20–50 ppm) é corrigível depois sem mudar a estrutura. |
| D8 | Vídeo **zero-copy**: todas as fontes entregam `CVPixelBuffer` com IOSurface; `CVMetalTextureCache` embrulha como `MTLTexture`. NDI e DeckLink custam um `memcpy` para um pool de IOSurfaces. Formatos: NV12 preferido (câmaras, descodificadores), BGRA (ecrã, imagens, sintético), UYVY (NDI, DeckLink). | Memória unificada do M1: a GPU nunca é o gargalo (medido: 8 camadas 1080p em 0,9 ms). |
| D9 | **Shaders compilados em tempo de execução** com `MTLDevice.makeLibrary(source:)` a partir de ficheiros `.metal` embebidos como texto. | O Metal Toolchain não está instalado (AMBIENTE.md). `.metallib` pré-compilada é optimização futura atrás do mesmo `ShaderLibrary`. |
| D10 | Compositor Metal: um render pass por bus (Program, Preview, Multiview). Modelo de camadas tipo vMix: base + 4 slots de overlay, transições cut/fade/wipe determinísticas em frames, T-bar. Um compute kernel converte Program BGRA → NV12 para os codificadores. | Igual nas quatro propostas. |
| D11 | **Encode-once, fan-out**: um `VTCompressionSession` por perfil (resolução/fps/bitrate); o mesmo bitstream vai para todos os destinos RTMP/SRT e para o gravador em passthrough. | O M1 tem **um** bloco codificador: ~200 fps agregados a 1080p (medido). Três codificações 1080p60 saturam-no. |
| D12 | Orçamento do codificador em "frames 1080p por segundo" calculado pelo motor e exposto no estado; a UI recusa configurações acima de 85 %. 2160p60 bloqueado nesta máquina. | Honestidade: 4K60 = 240/200. |
| D13 | Preview para a UI: **um stream multiview H.264** 1280×720@30 (opção 1920×1080), low-latency, sem B-frames, keyframe a pedido; stream de Program opcional 640×360@30. A UI recorta os tiles do frame descodificado. Fase 2: MJPEG como fallback para browsers sem WebCodecs. | Um stream por fonte custaria 8+ sessões de codificação. WebCodecs com descodificação por hardware verificado em Chromium 152 (AMBIENTE.md). |
| D14 | Etiquetas, tally e VU do multiview desenhados **pela UI** (DOM/canvas sobre os tiles, usando os rectângulos do layout no estado). Fase 2: versão com burn-in no motor para o projector "multiview". | Evita atlas CoreText na Fase 1; a UI já conhece o layout. |
| D15 | Saídas: RTMP/RTMPS e SRT via **HaishinKit 2.2.5** (BSD-3; passthrough de `CMSampleBuffer` comprimido verificado); gravação via `AVAssetWriter` passthrough, **.mov fragmentado** (1 s) na Fase 1, `.mp4` só depois de um teste `kill -9` confirmar ficheiro legível; NDI via `dlopen` de `libndi.dylib`; projector como `NSWindow` + `CAMetalLayer` no motor. | ffmpeg aqui é GPL e sem libsrt: só ferramenta de teste, nunca ligado. |
| D16 | Preview na Fase 1 mostra o projector como **janela nativa do motor** (não janela Electron). | Uma cópia a menos e cadência ligada ao display via `NSView.displayLink`. |
| D17 | NDI e DeckLink são **módulos opcionais** carregados dinamicamente; ordem de procura do runtime NDI em AMBIENTE.md; `/api/hello` anuncia capacidades. Fase 3: isolar SDKs de terceiros em serviços XPC com IOSurfaces partilhadas. | Não há SDK NDI nem Desktop Video instalados; o motor tem de compilar e testar sem eles. |
| D18 | Swift 6 com concorrência estrita **só na camada de controlo** (actors). Alvos de tempo real (`WTVVideo`, `WTVAudio`, shims C) compilam em modo de linguagem Swift 5 com classes finais, atomics e anéis lock-free. Sem `Task`/`await`/alocações nas threads de tempo real. | Evita inversões de prioridade e fricção com callbacks C (CoreAudio, VideoToolbox, libndi). |
| D19 | Persistência: `session.json` gravado a cada mutação (debounce 500 ms); ao reiniciar o motor restaura fontes e mistura; saídas que estavam no ar só reiniciam com `autoRestart` ligado. `engine.json` (0600) com `{pid, port, token, version, startedAt}`. | Reinício do motor em < 3 s sem perder o projecto. |
| D20 | Política de encerramento: a UI fechar nunca pára saídas em silêncio. Se algo está no ar pergunta "A emissão continua em segundo plano. Parar tudo?" e por omissão mantém o motor. `engine.shutdown` é um comando explícito. | Produto de emissão. |
| D21 | Autenticação: token aleatório de 32 bytes em `engine.json`; o Electron envia-o em `POST /api/session` e recebe cookie HttpOnly que os WebSockets levam. Fase 2 (LAN): PIN de 6 dígitos + QR, papéis `operador`/`visualizador`, TLS auto-assinado opcional. | Browsers não põem cabeçalhos em WebSocket; cookie resolve sem segredo no URL. |
| D22 | Gestão de memória: pools com limiar de alocação, `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` com escada de degradação (primeiro multiview fps e preview, nunca gravação/streams), alvo motor ≤ 1,8 GB RSS com 8×1080p, Electron ≤ 0,7 GB. Máximo 2 entradas 4K em simultâneo. | 8 GB partilhados com macOS (~2 GB). Swap destrói o tempo real. |

## 4. Processos e ciclo de vida

**Arranque.** O processo principal do Electron lê `~/Library/Application Support/WTV Studio/engine.json`. Se `GET /api/health` responder com o token certo, liga-se ao motor em execução ("Reconectado ao motor em execução"). Caso contrário lança `open -g -n -a "<Studio.app>/Contents/Helpers/WTV Engine.app" --args --port 7420 --data-dir ...`. O motor toma um `flock` em `engine.lock` (uma instância por utilizador), liga a `127.0.0.1:7420` (0.0.0.0 quando "Acesso remoto" está ligado), escreve `engine.json` e restaura `session.json`.

**Desenvolvimento.** `swift run wtv-engine --dev --port 7420` num terminal (as permissões TCC ficam atribuídas ao Terminal, uma vez) e `vite dev` em `:5173` a falar com `:7420` (CORS permitido para localhost). Os testes usam fontes sintéticas e ficheiros, por isso nunca pedem câmara.

**Falhas.** Renderer ou Electron a cair: o motor não nota. Motor a cair: o supervisor vê o WebSocket fechar e o pid morrer, relança em ≤ 1 s, o motor restaura a sessão; a UI mostra "O motor reiniciou — emissão retomada" no registo de eventos. Gravações são fragmentadas, por isso o ficheiro parcial fica legível. Fase 2: LaunchAgent com `KeepAlive` ("modo emissão") para que o launchd relance o motor mesmo sem o Electron.

**Empacotamento.** `engine/scripts/make-app-bundle.sh` monta `WTV Engine.app` a partir de `swift build -c release`; electron-builder copia-o com `extraFiles` para `Contents/Helpers/`. Assinatura com hardened runtime; entitlements do motor: `com.apple.security.device.camera`, `com.apple.security.device.audio-input`, `com.apple.security.cs.disable-library-validation` (necessário para `dlopen` de `libndi.dylib`, assinada pela Vizrt, e `DeckLinkAPI.framework`). `Info.plist` do motor: `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSCameraUseContinuityCameraDeviceType`, `NSLocalNetworkUsageDescription`, `NSBonjourServices` (`_ndi._tcp`, `_wtv._tcp`). Sem App Sandbox (distribuição directa). Identidade de assinatura estável em desenvolvimento, senão o TCC esquece as permissões a cada build.

## 5. Motor: threads e fluxo de dados

| Thread | Política | Faz |
|---|---|---|
| Main | AppKit run loop | Janela do projector, pickers, notificações de dispositivos, prompts TCC. |
| `VideoClock` | pthread tempo-constante, período = duração do frame, computação 2 ms, limite 6 ms | A cada tick N: escolhe por fonte o frame mais recente com `pts ≤ T − latência`, congela um `RenderPlan` imutável, codifica um command buffer Metal (Preview, Program, Multiview a meia cadência, conversão NV12), `commit`; o completion handler entrega a IOSurface do Program ao `OutputHub`. Tick atrasado > 1 frame: salta e conta `lateFrames`. |
| `AudioMixer` | pthread tempo-constante, 10 ms | Lê anéis SPSC de cada fonte, aplica ganho/mute/solo/AFV/atraso com rampas, escreve bus master e bus de monitorização, calcula VU. |
| Captura | fila serial `userInteractive` por `AVCaptureSession`/`SCStream`; uma thread por `AVAssetReader` (6 frames adiantados); uma thread bloqueante por receptor NDI (`NDIlib_recv_capture_v3`, timeout 100 ms) | Carimba com host time e escreve no `FrameStore` (triplo buffer, troca atómica). |
| `OutputHub` | fila serial | Recebe callbacks do VideoToolbox, distribui para sinks com filas limitadas (drop-oldest, nunca bloqueia o relógio). |
| NIO (2 loops) | SwiftNIO | HTTP, WebSockets, envio de preview com fila limitada por cliente (cliente lento perde frames até ao próximo keyframe). |
| Controlo | actors Swift | `StateStore`, `InputManager`, `OutputManager`, `DeviceWatcher`. Mutações → patch → broadcast. Comandos para as threads de tempo real vão por mailbox (troca atómica de ponteiro). |

**Sincronismo A/V.** Cada frame e bloco de áudio tem PTS em host time na origem. Latência por fonte: 1 frame para dispositivos, 3 frames para rede, 0 para sintético, mais `audioDelayMs` (±500) e `videoDelayFrames` ajustáveis pelo operador. Codificadores recebem vídeo e áudio na mesma base, por isso o lip-sync é o mesmo em stream, gravação, NDI e projector. Fonte sintética "Sincronismo" (flash + beep) e script com ffprobe medem o desvio nos testes.

## 6. Pipeline de vídeo

1. **Entrada** → `CVPixelBuffer` com IOSurface e `kCVPixelBufferMetalCompatibilityKey` (ver D8). Câmaras pedem `420v` com `alwaysDiscardsLateVideoFrames`; SCStream pede BGRA com `minimumFrameInterval` = cadência do projecto; AVAssetReader pede `420v` (descodificação por hardware implícita).
2. **FrameStore** por fonte: 3 slots, troca atómica.
3. **Texturas**: `CVMetalTextureCacheCreateTextureFromImage` por plano (NV12 → `.r8Unorm` + `.rg8Unorm`; BGRA → `.bgra8Unorm`; UYVY → `.bgrg422` com fallback de unpack no shader). Matriz de cor BT.709/601 e gama de valores lidas dos attachments do buffer, aplicadas no fragment shader.
4. **Compositor**: um quad por camada com uniforms `{transform, crop, opacity, colourSpace}`; blending premultiplicado. Fontes > 2× maiores que o destino passam por um mip de ¼ (compute pass por tick) para evitar aliasing; o mesmo mip serve o multiview.
5. **Transições**: `TransitionState {from, to, kind, startTick, durationTicks}` avaliado por tick → reproduzível. Cut, fade/mix, wipe (8 direcções com suavidade por distância assinada), dip-to-colour, FTB (também silencia áudio com rampa). Fase 2: stinger (clip com alfa ProRes 4444/HEVC, pré-carregado, corte no frame configurado). T-bar: a UI envia progresso 0..1 a ≤ 60 Hz; o motor arredonda ao tick.
6. **Saída**: compute kernel `bgraToNV12` escreve num `CVPixelBuffer` NV12 de um pool → `VTCompressionSession`, NDI (via `bgraToUYVY`), gravador. A textura BGRA alimenta o projector e o multiview.

Multiview: 1280×720 (ou 1920×1080) a metade da cadência; layouts em JSON (`{tiles: [{source, rect}]}`) partilhados com a UI para hotspots (clique = preview, duplo clique = cut).

## 7. Áudio

- Captura: `AVCaptureAudioDataOutput` para câmaras com áudio embebido; IOProc da HAL para interfaces (Volt 2); áudio de ficheiros via o mesmo `AVAssetReader` da imagem (sincronismo intrínseco); áudio de ecrã via ScreenCaptureKit.
- Mixer: float32 48 kHz, por fonte ganho, mute, solo, pan, atraso, AFV (segue a transição com a mesma curva), mapa de canais; bus master com limitador; bus de monitorização para o dispositivo escolhido; VU pico/RMS a 20 Hz em binário.
- Codificação AAC uma vez (AudioConverter) e fan-out para todos os destinos.
- Dispositivo mestre desaparece (USB desligado): o motor passa para um dispositivo nulo cadenciado pelo relógio, regista descontinuidade e continua.

## 8. Saídas

| Saída | Implementação | Notas |
|---|---|---|
| RTMP/RTMPS × N | HaishinKit `RTMPStream.append` com samples já comprimidos | Reconexão com backoff; estatísticas (bitrate, RTT, reconexões) a 1 Hz; chaves de stream no Keychain e mascaradas na UI. |
| SRT (Fase 2) | SRTHaishinKit (`libsrt` 1.5.x xcframework, MPL-2.0 inalterado) | Teste com uma segunda instância do motor como par (ffmpeg aqui não tem libsrt). |
| Gravação | `AVAssetWriter` passthrough, `.mov` fragmentado 1 s; divisão automática por tamanho; vigilante de disco pára a 1 GB livre | `.mp4` após teste `kill -9` com ffprobe. ISO (Fase 3) limitado a 2 × 1080p30 extra. |
| NDI | `dlopen` de `libndi.dylib`, `NDIlib_send_send_video_async_v2` com UYVY | ~0,5 núcleo a 1080p60. |
| Projector | `NSWindow` ecrã inteiro em qualquer `NSScreen`, `CAMetalLayer`, `NSView.displayLink` | Program ou Multiview. É monitor, não saída de emissão (sem genlock). |

Orçamento do codificador (1080p-frames/s, capacidade medida 200, margem 15 %): Program 1080p60 = 60; multiview 720p30 ≈ 13; preview Program 360p30 ≈ 4. Fase 1 ≈ 40 %, sobra espaço para uma segunda qualidade ou duas gravações ISO 1080p30. Program 2160p30 = 120 (60 %) com previews: possível, sem ISO. 2160p60 = 240: bloqueado.

## 9. Capacidade honesta neste Mac mini M1 8 GB

| Configuração | Veredicto |
|---|---|
| 1080p50/60, 8 fontes (3 UVC + 2 NDI full-bandwidth + 2 ficheiros + 1 ecrã), stream + gravação (mesmo bitstream) + NDI out + multiview + projector | **Sólido.** ≈ 3–4 núcleos, 40–50 % do codificador, GPU < 10 %, motor 1,3–1,8 GB. |
| 12–16 fontes a 1080p | Só se ≤ 4 forem descodificações comprimidas e ≤ 2 NDI full-bandwidth; as restantes UVC, imagens, sintético. |
| NDI full-bandwidth | ≤ 4 fontes 1080p60 (≈ 1 núcleo cada em SpeedHQ). As restantes em modo low-bandwidth até serem seleccionadas (truque clássico do vMix). |
| USB | ≈ 2 UVC 1080p60 sem compressão por controlador USB 3; câmaras MJPEG são mais baratas (descodificação JPEG por hardware). |
| 2160p25/30 Program, ≤ 2–3 fontes 4K, stream e gravação partilhando o perfil | **Possível**, a medir. Motor ≈ 2 GB. |
| 2160p50/60 | **Não suportado nesta máquina.** Precisa de M-series Pro/Max (dois blocos codificadores, 16–32 GB). O mesmo binário escala sem mudar o desenho. |
| Latência preview (glass-to-glass) | 80–120 ms a 30 fps. O projector (≈ 1 frame) é a referência. |
| Gravação 25 Mbps | ≈ 11 GB/h; 154 GB livres ≈ 13 h. |

A Fase 0 inclui um benchmark (`tools/bench`) que reescreve estes números para a máquina real e os guarda em `engine.json`; a UI usa-os no indicador "% codificador".

## 10. Disposição do repositório

```
VMIX_WTV/
├── docs/                    AMBIENTE.md, ARQUITECTURA.md, PROTOCOLO.md, CAPACIDADE.md, INSTALACAO.md
├── packages/protocol/       JSON Schema 2020-12 (fonte de verdade) + tipos TS gerados + fixtures
├── engine/                  SwiftPM
│   ├── Package.swift
│   ├── Sources/
│   │   ├── WTVProtocol/     DTOs Codable espelho do schema
│   │   ├── WTVCore/         relógio, StateStore, sessão, orçamento, logging
│   │   ├── WTVVideo/        compositor Metal, FrameStore, pools, shaders (texto)
│   │   ├── WTVAudio/        mixer, anéis, HAL, AAC
│   │   ├── WTVInputs/       Synthetic, Media, Camera, Screen, Image, Title, NDI, SRT, DeckLink
│   │   ├── WTVOutputs/      EncoderPool, RTMP, SRT, Recorder, NDIOut, Projector, PreviewEncoder
│   │   ├── WTVServer/       Hummingbird: HTTP estático, REST, /ws/control, /ws/preview
│   │   ├── CNDI/            shim C: dlopen + tabela de funções
│   │   ├── CDeckLink/       shim ObjC++ (Fase 3)
│   │   └── wtv-engine/      executável, CLI (--port, --bind, --dev, --headless, --scenario)
│   ├── Tests/
│   └── scripts/make-app-bundle.sh
├── apps/studio/             Electron (electron-vite): main, preload, renderer (React)
├── apps/ui/                 opcional: o renderer como pacote partilhado se crescer
├── tools/                   bench, rtmp-listener.sh, soak.sh, embed-shaders.sh
├── .cache/                  caches npm/Electron/SwiftPM (volume externo)
└── package.json             npm workspaces, scripts de topo
```

## 11. Pacotes de trabalho

| ID | Nome | Directório | Interfaces | Verificação | Depende de |
|---|---|---|---|---|---|
| WP1 | Protocolo | `packages/protocol`, `engine/Sources/WTVProtocol` | JSON Schema, tipos TS, DTOs Swift, fixtures | vitest valida fixtures Swift com ajv; `swift test` codifica/descodifica | — |
| WP2 | Núcleo do motor e servidor | `WTVCore`, `WTVServer`, `wtv-engine` | `StateStore` + patches, `/api/*`, `/ws/control`, `engine.json`, sessão | `swift test` relógio racional e patches; curl + wscat contra `--headless` | WP1 |
| WP3 | Compositor e fontes base | `WTVVideo`, `WTVInputs` (Synthetic, Media, Image, Title, Camera, Screen) | `InputSource` protocol, `FrameStore`, `RenderPlan` | testes golden-hash com fontes sintéticas; `/snapshot.png?bus=program` | WP2 |
| WP4 | Áudio | `WTVAudio` | anéis, `MixerCommand`, VU binário | testes de matemática de mistura; cenário flash+beep | WP2 |
| WP5 | Saídas e preview | `WTVOutputs` | `EncoderPool`, `StreamSink`, `/ws/preview` | ffmpeg `-listen` + ffprobe; `kill -9` durante gravação | WP3, WP4 |
| WP6 | Interface React | `apps/studio/src/renderer` | consome WP1; WebCodecs | vitest no store; smoke no painel de browser contra motor headless | WP1 |
| WP7 | Shell Electron e empacotamento | `apps/studio/src/main`, `engine/scripts`, `build/` | supervisor, `window.wtvDesktop` | lançar, fechar UI, verificar que o stream continua; `codesign -dvvv` | WP2, WP6 |
| WP8 | NDI, SRT, DeckLink | `CNDI`, `WTVInputs/NDI`, `WTVOutputs/NDIOut`, `CDeckLink` | capacidades em `/api/hello` | loopback NDI (runtime presente); SRT motor→motor | WP5 |
| WP9 | Testes de sistema | `tools/` | — | soak 60 min com 8 fontes a 1080p60: 0 drops, p99 jitter < 2 ms, RSS plano | WP5 |

## 12. Fases

**Fase 0 (spikes, 1 semana).** Prompt de câmara para o bundle lançado via `open` e persistência (verificar com `log stream --predicate 'subsystem == "com.apple.TCC"'`); shader em tempo de execução; HaishinKit a publicar samples pré-comprimidos para o ffmpeg ouvinte; benchmark do codificador.

**Fase 1 (utilizável).** WP1–WP7 e WP9: fontes sintéticas, ficheiros, imagens, câmaras AVFoundation, ecrã, títulos CoreText; cut/fade/wipe/FTB, 4 overlays, multiview; mixer com AFV; RTMP(S) × N; gravação `.mov` fragmentada; projector; preview WebCodecs; UI PT-PT em Electron e browser; sessão persistente; supervisor.

**Fase 2.** NDI in/out, SRT in/out, MJPEG fallback, acesso LAN com PIN/QR e TLS opcional, ASRC por fonte, stingers, `.mp4`, burn-in do multiview, "modo emissão" com LaunchAgent, gestão de memória e térmica completa.

**Fase 3.** DeckLink (experimental até validação em hardware real), gravação ISO, isolamento de SDKs em XPC, títulos HTML via Electron offscreen, câmara virtual, segundo perfil de qualidade.

## 13. Riscos residuais

| Risco | Gravidade | Mitigação |
|---|---|---|
| Bloco codificador único do M1 saturado por configuração do operador | Alta | Encode-once, orçamento medido, UI recusa > 85 %, 2160p60 bloqueado. |
| 8 GB: swap mata o tempo real | Alta | Pools, NV12, escada de pressão de memória, soak com RSS plano, janela única no Electron. |
| TCC mal atribuído ou assinatura instável → câmara "não existe" | Alta | Bundle via `open`, strings nos dois bundles, identidade de assinatura fixa, spike na Fase 0. |
| HaishinKit: churn de API, caminhos de recepção pouco exercitados | Média | Versão fixa 2.2.5, atrás de `StreamSink`/`NetInput`; plano B: cliente RTMP próprio (~1,5 k linhas), libsrt + demux TS próprio. |
| NDI/DeckLink não testáveis aqui | Média | Módulos opcionais com stubs; loopback NDI com o runtime do plugin DAL; validação em máquina da WayTV antes de fechar Fase 2/3. |
| Deriva de relógio de áudio USB em programas longos | Média | Medição desde o dia um, ASRC na Fase 2, controlos de atraso por fonte. |
| Swift 6 vs. tempo real | Média | Alvos RT em modo Swift 5, sem actors/alocações nas threads RT, histograma de jitter p99 < 2 ms nos testes. |
| `.mp4` fragmentado não legível após crash | Baixa | `.mov` por omissão até o teste passar. |
| Licenças (ffmpeg GPL, libsrt MPL, EULA NDI/BMD) | Baixa | ffmpeg só como ferramenta; `THIRD_PARTY.md`; runtimes de terceiros instalados pelo utilizador. |
| Lembrete mensal do macOS para captura de ecrã | Baixa | `SCContentSharingPicker`; painel "Permissões" antes de ir para o ar. |
