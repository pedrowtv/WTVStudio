# WTV Engine sobre a libobs (D23)

Motor em C++ que substitui o motor Swift (`engine/`) mantendo o mesmo contrato com a interface
([docs/PROTOCOLO.md](../docs/PROTOCOLO.md)): JSON-RPC 2.0 em `/ws/control`, estado por snapshot + JSON Patch,
preview multiview H.264 em `/ws/preview` (cabeçalho WTVF), UI estática servida pelo próprio motor.

```
src/ObsRuntime.*     arranque da libobs (vídeo, áudio, módulos), reset de formato, escolha do codificador
src/StateStore.*     EngineState em nlohmann::json, rev monótono, diff RFC 6902 por mutação, histórico para resync
src/Switcher.*       Preview/Program: canal 0 = cena Program (transição cut/fade/wipe/dip em baixo + 4 slots de
                     overlay, cada um uma transição fade sobre uma cena privada com rect/crop/opacidade); T-bar; FTB;
                     fontes (cor, ficheiro, SRT via ffmpeg_source, imagem, oráculo FreeType, câmara, ecrã);
                     cena multiview privada renderizada num obs_view próprio a 1280×720
src/PreviewOutput.*  saída libobs própria (OBS_OUTPUT_ENCODED) que entrega os pacotes H.264 do multiview;
                     Annex B → AVCC, avcC a cada keyframe
src/ControlServer.*  civetweb: HTTP (UI, /api/session, /api/health) + WebSockets de controlo e preview
src/Commands.*       despacho dos métodos JSON-RPC
src/NDI.*            NDI sobre o shim `src/cndi` (libndi por dlopen, D17): fonte `wtv_ndi_source` (BGRA assíncrono + áudio
                     float planar, modo low bandwidth), saída `wtv_ndi_output` (raw BGRA + áudio do barramento NDI),
                     descoberta de fontes (devices.ndiSources, actualizada de 5 em 5 s e em devices.refresh)
src/Projector.*      janela AppKit com obs_display (Program, multiview ou fonte), ajustada ao raster; ecrã inteiro só em
                     ecrãs externos; Esc/Cmd+W fecham; o main thread corre o NSApp e o motor corre numa thread própria
src/AudioEngine.*    VU por fonte (obs_volmeter, true peak) e por barramento (callbacks das tracks 1–3 = Master/A/B),
                     ganho, pan, atraso, mute, solo, AFV (fonte fora do ecrã na cena Program quando desligado),
                     barramentos por fonte (máscara de tracks), monitorização por barramento, filtros da libobs
                     como plugins (RNNoise, gate, compressor, limitador, expander, EQ, ganho); stream 16 a 10 Hz
src/Outputs.*        codificadores de Program partilhados (encode-once: VideoToolbox H.264 + CoreAudio AAC),
                     saídas RTMP (rtmp_output) e SRT (ffmpeg_mpegts_muxer) com serviço rtmp_custom, reconexão
                     e estado por sinais start/stop/reconnect; gravação via ffmpeg_muxer
poc/                 prova de conceito inicial (cor + texto → mp4)
run-dev.sh           arranca em modo --dev na porta 7421 a servir apps/studio/out/renderer
scripts/make-app-bundle.sh  monta dist/WTV Engine.app (ver docs/INSTALACAO.md); bundle/ Info.plist e entitlements
```

Compilar (depois do OBS; ver [docs/INSTALACAO.md](../docs/INSTALACAO.md)):

```bash
cmake -S engine-obs -B ~/.cache/wtv-obs/engine-build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build ~/.cache/wtv-obs/engine-build
```

Estado (2026-10-23): verificado com a UI Electron compilada e com um script de teste JSON-RPC:
hello/snapshot, patches e resync, input.add/remove/reorder, setPreview, cut, fade/wipe/dip com troca
Preview↔Program no fim (sinal `transition_stop` da libobs), T-bar manual, FTB, áudio por canal (volume/mute),
media play/pause/stop/seek/loop com posição no estado, preview multiview ~50 fps com keyframe por segundo,
gravação mp4, overlays 1–4 no Program (verificado em frame gravado), RTMP para ffmpeg local (7 s H.264+AAC),
SRT em loopback entre a saída e a entrada do próprio motor (o ffmpeg do Homebrew não tem libsrt).
Nota: fontes de rede (ffmpeg_source) levam `restart_on_activate=false` para correrem sem estar em Program.
Áudio verificado com um clip de tom: VU por fonte e barramento, ganho −20 dB, bus A/Master, AFV, mute, RNNoise,
barramento das saídas (audio.setOutputBus, só com saídas paradas). NDI verificado em loopback nesta máquina: saída live, fonte descoberta, entrada live, uma passagem mantém as cores
(±10 níveis, codec SpeedHQ). Atenção nos testes: pôr a entrada NDI em Program enquanto a saída NDI envia o Program cria
um loop de vídeo que escurece as cores a cada volta; não é defeito do motor. O runtime vem da cópia dentro do plugin DAL
da NewTek (ver docs/AMBIENTE.md) ou de `WTV_NDI_PATH`. OMT (Open Media Transport, MIT): a libomt é um wrapper C sobre
um binário .NET pré-compilado (libomt + libvmx .dylib); fica para carregar por dlopen como o NDI quando houver release
estável para macOS arm64.
Projector e parâmetros dos filtros (audio.getPluginParams/setPluginParam via obs_properties; a UI edita-os no ⚙ do
plugin) verificados: janela com Program + overlay no ecrã principal, compressor com threshold/ratio alterados.
Empacotamento feito: WTV Engine.app com token/cookie/Origin, engine.json e log; a app Electron lança-o e liga.
Por fazer:
ganho Master,
projector, token/cookie fora de `--dev`, engine.json para o Electron, empacotamento em `WTV Engine.app`.
