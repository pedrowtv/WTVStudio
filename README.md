# WTV Studio

Misturador de vídeo ao vivo tipo vMix. Interface em Electron + React; motor nativo em Swift (Metal, VideoToolbox, AVFoundation) no Mac. Licença **GPL-2.0** (ver `LICENSE`).

Direcção a partir de 2026-10-23 (decisão D23): o motor passa a ser **C++ sobre a libobs** (OBS Studio), para um só motor em macOS (Metal) e Windows (Direct3D 11), mantendo a interface Electron e o protocolo. O motor Swift fica como protótipo de referência enquanto a migração não estiver completa. O motor novo vive em [engine-obs/](engine-obs/README.md) e já corre a interface com Preview/Program, transições, T-bar, FTB e preview multiview.

- [docs/ARQUITECTURA.md](docs/ARQUITECTURA.md) — decisões, processos, pipeline, capacidade, fases.
- [docs/PROTOCOLO.md](docs/PROTOCOLO.md) — contrato motor ⇄ interface (JSON-RPC, estado, preview binário).
- [docs/AMBIENTE.md](docs/AMBIENTE.md) — factos verificados nesta máquina.
- [docs/INSTALACAO.md](docs/INSTALACAO.md) — construir, empacotar, permissões e arranque.

## Estrutura

```
packages/protocol   tipos partilhados, cabeçalho binário, JSON Patch (TypeScript)
engine/             motor Swift (SwiftPM): WTVProtocol, WTVCore, WTVServer, módulos de tempo real
apps/studio/        aplicação Electron (electron-vite) com o renderer React
tools/              scripts de teste (ouvinte RTMP, etc.)
```

## Desenvolvimento

Pré-requisitos: Xcode 26 (Swift 6.3), Node 22+, ffmpeg (só para testes).

```bash
npm install
npm run engine:build        # compila o motor (caches em .cache/)
npm run engine:test         # testes Swift
npm test                    # testes TypeScript (vitest)
```

Correr o motor em modo de desenvolvimento (sem token) e a interface:

```bash
npm run engine:run
```

```bash
npm run studio:dev
```

A interface liga a `http://127.0.0.1:7420`. Um browser pode abrir o mesmo endereço quando o motor é lançado com `--ui apps/studio/out/renderer`.

## Estado do projecto

Passos 1–7 do plano feitos: motor com relógio de tempo real, compositor Metal (cut/fade/wipe/dip/FTB, 4 overlays, multiview), preview H.264 por WebSocket descodificado com WebCodecs, mixer de áudio com VU e monitorização, fontes reais (ficheiros, imagens, oráculos CoreText, câmaras AVFoundation, captura de ecrã) e saídas: codificador de Program partilhado (H.264 High + AAC-LC, encode-once), gravação `.mov` fragmentada, RTMP/RTMPS via HaishinKit, saída NDI via `libndi` carregada dinamicamente e janela de projector Metal. Verificado nesta máquina com o ffmpeg como ouvinte RTMP e o ffprobe nas gravações. A interface (passo 8) segue o layout clássico do vMix com aspecto moderno: monitor Preview (laranja) à esquerda e Program (verde) à direita com tempo e transporte de media, coluna central com Quick Play / Cut / Fade / Wipe / Dip / FTB, botões de overlay 1–4 e T-bar vertical, faixa de miniaturas com Fechar / Quick Play / Cut / Loop / ▶, overlays 1–4 e Áudio por fonte, barra inferior com Adicionar fonte, Gravar, Stream, Externo (NDI) e Overlay, e barra de estado (formato, preview, codificador, térmico). Audio Mixer, Fontes, Saídas, Overlays e Definições abrem em modais. Atalhos: 1–9 preview, Enter cut, Espaço fade, F FTB, Esc fecha modais. Todos os monitores e miniaturas são recortes do único stream multiview descodificado com WebCodecs. Projectos guardam-se e abrem-se em JSON (`project.save` / `project.load`). Empacotamento (passo 9) feito: `engine/scripts/make-app-bundle.sh` monta `WTV Engine.app` com a UI dentro, assinado ad-hoc; `electron-builder` produz `release/mac-arm64/WTV Studio.app` que lança o motor via LaunchServices, carrega a UI do motor e autentica por token trocado por cookie. Verificado nesta máquina. Faltam SRT, o acesso LAN com PIN, assinatura com Developer ID / notarização e os testes de longa duração.

Teste rápido de RTMP local:

```bash
tools/rtmp-listener.sh 19350 10
```

Depois, na interface, "+ RTMP" com `rtmp://127.0.0.1:19350/live` e chave `test`, e "Iniciar".

Correcções de 2026-10-23 (revisão adversarial e relatos do utilizador): o projector abre sempre em janela no ecrã principal (ecrã inteiro só em ecrãs externos), responde a Esc/Cmd+W e corre o ciclo de eventos do AppKit (antes tapava o Mac sem saída); `window.prompt` substituído por diálogos nativos (ficheiros, imagens, pasta de gravação) e uma caixa de texto própria, porque o Electron não implementa `prompt`; pasta e formato de gravação configuráveis em Saídas; projectos confinados a `~/Library/Application Support/WTV Studio/projects`; token novo a cada arranque, cookie de sessão separado do token, verificação de `Origin` nos WebSockets, `--dev` só em loopback; replay de `txnId`; layout da estrutura NDI corrigido; pacotes RTMP em fila FIFO; PTS de áudio contínuo; atalhos desligados com modais abertos.

Acrescentado a 2026-10-23 (pedidos do utilizador): **entrada NDI** (descoberta na rede, recepção BGRA + áudio, modo low-bandwidth), **SRT** entrada e saída (saída via HaishinKit; entrada própria sobre a libsrt com desmultiplexador MPEG-TS, H.264/HEVC por VideoToolbox e AAC por AudioConverter, caller ou listener, latência e passphrase), **barramentos de áudio** Master / A / B com envio por canal, monitorização por barramento e barramento por saída (stream+gravação, NDI), e **plugins Audio Unit** por canal (23 AUs encontrados nesta máquina; cadeia por canal, bypass, janela de parâmetros com a vista própria do plugin ou a vista genérica). Tudo verificado em loopback nesta máquina.

Notas: a captura de ecrã precisa da permissão "Gravação de Ecrã" para o processo que lança o motor; em desenvolvimento é o Terminal. Não há câmaras ligadas nesta máquina, por isso o caminho AVFoundation está compilado mas não testado com hardware.

Definições (2026-10-23): painel com barra lateral à maneira do vMix e páginas à maneira do OBS — Vídeo (formato, multiview, renderização), Stream e codificação (bitrates, keyframe, perfil, CBR/VBR, barramentos das saídas), Gravação (pasta, contentor), Áudio (monitor, matriz de barramentos M/A/B + AFV), Projector (ecrã, conteúdo, ecrã inteiro), Atalhos, Rede e dispositivos (NDI, ecrãs, saídas de áudio), Motor e registo. Só mostra o que o motor libobs suporta.

Playout (2026-10-23): fonte "Playout" que toca uma lista de ficheiros em sequência (in/out por item, repetir lista, saltar, seguinte), com painel próprio no botão Playout e importação/exportação no formato de playlist do ffplayout (adoptou-se só o formato: o ffplayout é GPL-3 e Rust, o OBS é GPL-2, não se mistura código). Limitação: o salto ao ponto in cai no keyframe anterior.

## Plugins Audio Unit de terceiros

O motor lista todos os Audio Units instalados no sistema (`AudioComponentFindNext`). Para instalar um plugin sem palavra-passe de administrador basta copiar o `.component` para `~/Library/Audio/Plug-Ins/Components/` (um `.pkg` pode ser aberto com `pkgutil --expand-full` para extrair o bundle). Validar com `auval -v <tipo> <subtipo> <fabricante>`. Plugins VST3 não são suportados: o motor só aloja Audio Units.
