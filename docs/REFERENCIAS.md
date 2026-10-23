# Referências externas analisadas

## FreeMix 0.1.0-alpha (eddysangalli; GPL-2.0, com autorização do autor)
Painel HTML/JS de 640 linhas (`painel/mesa.html`) sobre o obs-websocket 5 dentro de um dock CEF do OBS, scripts PowerShell
para Windows (splash, título da janela, empacotar), tema `.ovt` do OBS e cenas de demonstração. Ideias aproveitadas: separadores
de categorias na faixa de fontes, modo Operar/Compor, buses M/A/B, chamadas por VDO.Ninja em fonte de browser, gravação ISO.
Nada de código reutilizado (modelo e motor diferentes). A pasta `FreeMix-0.1.0-alpha/` fica fora do git.

## FreeMix IO 0.4.0 (binário Windows, pasta `plugis/FreeMixIO`)
Desmontagem (2026-10-23): executável nativo C++ x86-64 compilado com GCC 16 (MinGW), sem .NET. Ficheiros de origem visíveis nos
símbolos: `main, app, capture, devices, pipe, proc, output, preview, http, pages, link, srt, ndi_api, omt_api, config, util`.
Como está montado:
- **Captura**: lança o `ffmpeg.exe` externo (DirectShow, ficheiro em loop ou fonte de teste) e lê vídeo UYVY + áudio por *pipe*.
- **Publicação**: OMT via `libomt.dll` (API C: `omt_send_create/omt_send/omt_receive_create/omt_receive/omt_discovery_getaddresses`,
  tally, metadata, estatísticas) com o codec `libvmx.dll`; NDI via `Processing.NDI.Lib.x64.dll` carregada dinamicamente (NDI 5/6).
- **SRT**: entrada e saída em MPEG-TS H.264/HEVC + AAC através do ffmpeg (listener/caller/rendezvous, AES, stream id), abertura
  automática de porta por UPnP (SOAP `AddPortMapping`), NAT-PMP/PCP; túnel ZeroTier por `zerotier-cli`.
- **Painel**: servidor HTTP próprio na porta 8090 (settings.xml) com as páginas HTML embutidas no executável e uma API
  `/query?status|sources|formats|getCaps|log`; "Studio Link" codifica host/porta/latência/senha num código partilhável.
- **Limites**: 16 entradas + 16 saídas; OMT recomendado para 8+8 em 1 GbE; NDI sem compressão ~440 Mbps por 720p30.
Relevância para o WTV Studio: confirma a arquitectura "caixa de captura na rede + misturador"; a lista de exports da libomt serve de
guia para a futura entrada/saída OMT no motor (precisamos da `libomt.dylib` para macOS). Sem código reutilizável (binário).
