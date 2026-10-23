# WTV Engine sobre a libobs (D23)

Motor em C++ que substitui o motor Swift (`engine/`) mantendo o mesmo contrato com a interface
([docs/PROTOCOLO.md](../docs/PROTOCOLO.md)): JSON-RPC 2.0 em `/ws/control`, estado por snapshot + JSON Patch,
preview multiview H.264 em `/ws/preview` (cabeçalho WTVF), UI estática servida pelo próprio motor.

```
src/ObsRuntime.*     arranque da libobs (vídeo, áudio, módulos), reset de formato, escolha do codificador
src/StateStore.*     EngineState em nlohmann::json, rev monótono, diff RFC 6902 por mutação, histórico para resync
src/Switcher.*       Preview/Program: canal 0 = fonte de transição (cut/fade/wipe/dip); T-bar manual; FTB;
                     fontes (cor, ficheiro, SRT via ffmpeg_source, imagem, oráculo FreeType, câmara, ecrã);
                     cena multiview privada renderizada num obs_view próprio a 1280×720
src/PreviewOutput.*  saída libobs própria (OBS_OUTPUT_ENCODED) que entrega os pacotes H.264 do multiview;
                     Annex B → AVCC, avcC a cada keyframe
src/ControlServer.*  civetweb: HTTP (UI, /api/session, /api/health) + WebSockets de controlo e preview
src/Commands.*       despacho dos métodos JSON-RPC; gravação via ffmpeg_muxer (VideoToolbox + CoreAudio AAC)
poc/                 prova de conceito inicial (cor + texto → mp4)
run-dev.sh           arranca em modo --dev na porta 7421 a servir apps/studio/out/renderer
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
gravação mp4. Por fazer: overlays no compositor, saídas RTMP/SRT/NDI, barramentos/plugins de áudio, VU,
projector, token/cookie fora de `--dev`, engine.json para o Electron, empacotamento em `WTV Engine.app`.
