# Ambiente verificado (2026-10-17)

Factos medidos nesta máquina, não suposições. Qualquer decisão de arquitectura deve respeitá-los.

## Máquina

| Item | Valor |
|---|---|
| Modelo | Mac mini, Apple M1 (8 núcleos) |
| Memória | 8 GB unificada |
| macOS | 26.3.1 (Darwin 25.3.0) |
| Ecrã | 2560 x 1440 (único) |
| Disco do projecto | `/Volumes/Pedro Work/VMIX_WTV` (volume externo, 154 GB livres; o caminho tem um espaço) |
| Áudio | Universal Audio Volt 2 Gen 2 (6 in / 8 out, dispositivo por omissão); LG ULTRAGEAR; "NDI Audio" virtual (2 in / 6 out) |
| Câmaras | Nenhuma ligada neste momento (AVFoundation enumera 0 dispositivos de vídeo) |
| Blackmagic Desktop Video | Não instalado |

## Toolchain

| Ferramenta | Versão |
|---|---|
| Xcode | 26.5 (instalação completa, compilador Metal disponível em `xcrun metal`) |
| Swift / SwiftPM | 6.3.2 |
| Node / npm | 25.9.0 / 11.12.1 |
| git | 2.50.1 (user Pedro Miguel Moreira, geral@waytv.pt) |
| ffmpeg (Homebrew) | 8.1.1 com videotoolbox, libx264, libx265, libopus, libvpx, libsvtav1, libdav1d, openssl. Protocolos: rtmp, rtmps, http(s), tcp, udp, pipe, fd, unix. **Sem libsrt, sem NDI, sem DeckLink.** Dispositivos: avfoundation, lavfi. Codificadores: h264_videotoolbox, hevc_videotoolbox, prores_videotoolbox, aac, aac_at |
| Python | 3.9.6 (sistema) |
| Ausentes | GStreamer, cargo, cmake, pkg-config, ninja, pnpm, yarn, `timeout` (coreutils) |

## NDI

- NDI Tools está instalado: driver NDI|HX em `/Library/Application Support/NewTek/NDI/HX_Driver/`, drivers de áudio `NDIAudio.driver` e `NDIAudioOut.driver` em `/Library/Audio/Plug-Ins/HAL/`, plugin de câmara virtual `/Library/CoreMediaIO/Plug-Ins/DAL/NDIVideoOut.plugin` e daemon `com.newtek.cmio.DPA.NDI`.
- O runtime oficial **não** está em `/usr/local/lib/libndi.dylib` nem em `/Library/NDI SDK for Apple/`.
- Existe uma cópia utilizável do runtime em `/Library/CoreMediaIO/Plug-Ins/DAL/NDIVideoOut.plugin/Contents/Frameworks/libndi.dylib`: binário universal (x86_64 + arm64), "NDI SDK APPLE 6.2.1.0", 132 símbolos `NDIlib_*` exportados (find, recv v3, send, etc.).
- Teste em Swift com `dlopen` + `dlsym` (scratchpad `ndi-smoke/ndi.swift`): `NDIlib_initialize` devolve true, criação de emissor OK, descoberta local do próprio emissor OK (`MAC-MINI-DE-PEDRO.LOCAL (WTV Smoke Test)` em 127.0.0.1:5961). **NDI pode ser desenvolvido e testado em loopback nesta máquina.**
- Ordem de procura recomendada para o runtime: `$NDI_RUNTIME_DIR_V6/libndi.dylib`, `/usr/local/lib/libndi.dylib`, `/Library/NDI SDK for Apple/lib/macOS/libndi.dylib`, e por fim a cópia dentro do plugin DAL. O motor deve carregar NDI dinamicamente e funcionar sem ele.

## Electron 44.9.0 (Chromium 152) nesta máquina

Medido com um BrowserWindow oculto (`contextIsolation: true`, `sandbox: true`), scratchpad `electron-smoke/main3.js`:

| Capacidade | `file://` | `http://127.0.0.1` com COOP/COEP |
|---|---|---|
| Contexto seguro | sim | sim |
| `crossOriginIsolated` | não | sim |
| `VideoDecoder` / `VideoEncoder` / `AudioDecoder` (WebCodecs) | disponíveis | disponíveis |
| `SharedArrayBuffer` | **indisponível** | disponível |
| WebGPU (`navigator.gpu`, adapter) | disponível | disponível |
| WebGL2 | ANGLE Metal Renderer: Apple M1 | idem |

Descodificação por hardware (`prefer-hardware`, 1920x1080): H.264 Baseline/Main/High **sim**, H.264 High 3840x2160 **sim**, HEVC Main **sim** (só hardware), VP9 **sim**, AV1 **só software**.
Codificação por hardware (720p30): H.264 High **sim**, HEVC **sim**, H.264 Baseline (`avc1.42E01E`) **não** (usar Main/High).
`app.getGPUFeatureStatus()`: video_decode, video_encode, gpu_compositing e webgpu = enabled.

Consequências:
- Um URL `data:` **não** é contexto seguro: WebCodecs fica indefinido. A interface deve ser carregada de `file://` ou de `http://127.0.0.1`.
- Para usar `SharedArrayBuffer`, servir a interface por HTTP com COOP/COEP ou registar um protocolo personalizado com esses cabeçalhos.

## Versões mais recentes no registo npm (2026-10-17)

electron 44.9.0, electron-vite 6.0.0, react 19.3.1, typescript 7.0.2, vite 8.3.4, vitest 5.0.5, zustand 5.0.15, ws 8.22.0, electron-builder 26.15.3. HaishinKit.swift 2.2.5 (RTMP/SRT em Swift).

## Metal e SwiftPM

- O Xcode 26.5 **não tem o componente Metal Toolchain instalado**: `xcrun metal` falha com "missing Metal Toolchain; use: xcodebuild -downloadComponent MetalToolchain". Não há compilação offline de shaders nem geração de `.metallib`.
- Um pacote SwiftPM com um ficheiro `.metal` em `resources: [.process("Shaders")]` compila sem erro mas `makeDefaultLibrary(bundle: Bundle.module)` falha com "no default library was found" (scratchpad `spm-metal`).
- `MTLDevice.makeLibrary(source:options:)` **funciona** (compilação em tempo de execução). Decisão: o motor guarda os shaders como texto (`.metal` copiados como recurso ou strings Swift) e compila-os ao arrancar; o Metal mantém cache no disco. Se um dia o Metal Toolchain for instalado, pode-se adicionar uma `.metallib` pré-compilada como optimização.

## Espaço em disco (atenção)

- Disco interno do Mac: **3,0 GB livres** em 2026-10-17 17:20. `~/.npm` ocupa 1,8 GB, `~/Library/Caches/electron` 125 MB.
- Regras do projecto: `.npmrc` redirecciona as caches do npm, do Electron e do electron-builder para `.cache/` dentro do projecto (volume externo); `swift build` deve usar `--scratch-path .build --cache-path ../.cache/swiftpm` (ver scripts npm). O scratchpad dos testes vive em `/private/tmp` (disco interno) e deve ser limpo depois de cada experiência.

## Verificação de streaming local

- `ffmpeg -listen 1 -i rtmp://127.0.0.1:19350/live/test -c copy -t 6 recv.flv` aceita uma ligação RTMP; um push de teste com `testsrc2` + `sine`, `h264_videotoolbox` + `aac`, chegou inteiro (5,03 s, 1280x720 30 fps H.264 + AAC 48 kHz). O ciclo "motor → RTMP → ffmpeg ouvinte → ffprobe" serve para testes automáticos sem servidor externo.

## HaishinKit 2.2.5 (RTMP/SRT em Swift)

- Resolve e compila com Swift 6.3.2 em modo release neste Mac (scratchpad `spm-haishin`). Plataformas: iOS 15+, macOS 12+. Produtos: `HaishinKit` (RTMP), `SRTHaishinKit` (SRT, traz `libsrt.xcframework` 1.5.4 como artefacto binário), `MoQTHaishinKit`, `RTCHaishinKit` (traz `libdatachannel` 0.24.0). Dependência extra: Logboard 2.6.0.
- Tipos públicos relevantes: `MediaMixer`, `StreamConvertible`, `StreamOutput`, `StreamRecorder`, `Session`/`SessionBuilder`, `VideoCodecSettings`, `AudioCodecSettings`, `StreamBitRateStrategy`, `NetworkMonitorReport`; em SRT: `SRTConnection`, `SRTStream`, `SRTSocketOption`, `SRTPerformanceData`.
- Consequência: a saída RTMP/RTMPS e SRT pode ser feita em Swift sem passar pelo ffmpeg (que aqui não tem libsrt). A entrada SRT fica por confirmar (`SRTStream` em modo play).

## Áudio: coreaudiod bloqueado (verificado em 2026-10-23)

- Criar um IOProc na **Volt 2 Gen 2** (dispositivo de saída por omissão) ou no **NDI Audio** bloqueia para sempre em `mach_msg` para o `coreaudiod`; até o `afplay` do sistema fica pendurado. As **Colunas (Mac mini)** funcionam (IOProc a 48 kHz OK). Consultas de propriedades à HAL respondem **até** o processo tentar abrir um dispositivo bloqueado; a partir daí todas as chamadas à HAL nesse processo bloqueiam.
- `AVAudioEngine` bloqueia logo ao aceder a `outputNode`/`mainMixerNode` (abre o dispositivo por omissão). Por isso o motor usa IOProc da HAL num dispositivo escolhido, com watchdog de 2 s, e um relógio nulo de 10 ms quando a saída não abre (`AudioMixer.openOutput`). Depois de um bloqueio o motor marca a HAL como indisponível e não volta a chamá-la até reiniciar.
- Estado da máquina, não do código: um reinício do Mac (ou `sudo killall coreaudiod`, que interrompe todo o áudio) deve resolver. A escolha do dispositivo de monitorização persiste em `session.json` (`audio.monitor.deviceId`), por isso o motor pode arrancar directamente nas colunas internas.

## Permissões em desenvolvimento (2026-10-23)

- ScreenCaptureKit devolveu `PERMISSION_DENIED` (erro -3801) quando o motor foi lançado a partir do agente/terminal: a permissão "Gravação de Ecrã" é atribuída ao processo responsável (o Terminal ou a app que lança o motor). Para testar captura de ecrã em desenvolvimento, dar essa permissão ao Terminal em Definições do Sistema → Privacidade e Segurança → Gravação de Ecrã.
- `AVCaptureDevice.DiscoverySession` continua a enumerar 0 câmaras; `state.devices.video` fica vazio até ligar uma câmara USB ou activar a Continuity Camera.
