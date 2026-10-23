# WTV Studio — Protocolo de controlo e preview (v1)

Contrato entre o motor (`WTV Engine.app`) e qualquer cliente (renderer Electron ou browser na LAN). A fonte de verdade é o JSON Schema em `packages/protocol/schema/`; os tipos TypeScript são gerados a partir dele e os DTOs Swift em `WTVProtocol` são verificados contra as mesmas fixtures.

Identificadores em inglês. Mensagens de erro são códigos; a UI traduz para PT-PT.

## 1. Transporte

| Endpoint | Tipo | Função |
|---|---|---|
| `GET /` | HTTP | Bundle da interface (o mesmo do Electron). |
| `GET /api/health` | HTTP | `{ok, version, uptimeSeconds}`; sem auth. |
| `GET /api/hello` | HTTP | Versão, id do projecto, `capabilities` (`ndi`, `srt`, `decklink`, `webcodecsHint`), `bind`. |
| `POST /api/session` | HTTP | Corpo `{token}` (loopback) ou `{pin}` (LAN, Fase 2). Devolve cookie `wtv_session` HttpOnly. |
| `GET /api/state` | HTTP | Snapshot completo `{rev, state}`. |
| `GET /api/devices` | HTTP | Câmaras, dispositivos de áudio, ecrãs, fontes NDI (também em `state.devices`). |
| `GET /api/media?dir=` | HTTP | Listagem de pastas de media configuradas. |
| `PUT /api/inputs/{id}/image` | HTTP | PNG com alfa para fontes de imagem/título. |
| `GET /api/snapshot.png?bus=program\|preview\|multiview` | HTTP | Frame actual em PNG (testes). |
| `GET /api/preview/mjpeg?stream=&size=&fps=` | HTTP | Fallback MJPEG `multipart/x-mixed-replace` (Fase 2). |
| `GET /api/metrics` | HTTP | Contadores internos em JSON. |
| `ws://host:7420/ws/control` | WebSocket texto | JSON-RPC 2.0: comandos, snapshot, patches, eventos, telemetria. |
| `ws://host:7420/ws/preview?stream=multiview\|program` | WebSocket binário | Frames H.264 (ver §5). |

Ligação por omissão `127.0.0.1:7420`. Com "Acesso remoto" ligado: `0.0.0.0:7420` e anúncio Bonjour `_wtv._tcp`. Ambos os WebSockets exigem o cookie de sessão.

## 2. Mensagens de controlo (JSON-RPC 2.0)

Cliente → motor (pedido):

```json
{"jsonrpc":"2.0","id":17,"method":"switcher.transition","params":{"kind":"fade","durationFrames":25}}
```

Motor → cliente (resposta):

```json
{"jsonrpc":"2.0","id":17,"result":{"rev":4812}}
{"jsonrpc":"2.0","id":17,"error":{"code":-32001,"data":{"code":"ENCODER_BUDGET","detail":"..."},"message":"encoder budget exceeded"}}
```

Motor → cliente (notificações, sem `id`):

| `method` | `params` | Cadência |
|---|---|---|
| `state.snapshot` | `{rev, state}` | Ao ligar, ao pedir `state.resync`, quando há lacuna. |
| `state.patch` | `{fromRev, toRev, ops:[RFC 6902]}` | A cada mutação (coalescida por 16 ms). |
| `stats` | `{inputs:{id:{fps,dropped,repeated}}, outputs:{id:{bitrateKbps,rttMs,reconnects,droppedFrames}}, system:{cpu,rssMB,gpuMs,encoderPercent,thermal,lateFrames}}` | 1 Hz. Nunca entra no estado. |
| `log` | `{level, code, message, at}` | Quando acontece. |
| `engine.restarted` | `{previousPid}` | Uma vez após reinício. |

Regras:

- O cliente aplica um patch só se `fromRev == lastRev`; caso contrário chama `state.resync` e recebe um snapshot. O motor guarda um anel de 2 000 patches para repor lacunas curtas.
- Comandos não idempotentes (`switcher.transition`, `output.start`, `media.play`, `record.start`) levam `params.txnId` (UUID do cliente); o motor guarda os últimos 60 s para tornar repetições seguras após reconexão.
- Ping/pong a cada 5 s; o cliente considera a ligação morta após 2 falhas e reconecta com backoff 250 ms → 5 s, re-login com o cookie, snapshot, pedido de keyframe.

### Códigos de erro

`-32600..-32603` são os do JSON-RPC. Erros de domínio usam `-32000` com `data.code`:

`INPUT_NOT_FOUND`, `OUTPUT_NOT_FOUND`, `INVALID_PARAMS`, `ENCODER_BUDGET`, `MEMORY_BUDGET`, `DEVICE_UNAVAILABLE`, `PERMISSION_DENIED`, `ALREADY_RUNNING`, `NOT_RUNNING`, `DISK_FULL`, `CAPABILITY_MISSING`, `UNAUTHORIZED`, `ROLE_FORBIDDEN`.

## 3. Métodos

| Método | `params` | Efeito |
|---|---|---|
| `session.hello` | `{clientKind:"electron"\|"browser", clientName, lastRev?}` | Primeiro pedido; devolve `{engineVersion, capabilities, snapshot}`. |
| `state.resync` | `{lastRev}` | Patches em falta ou snapshot. |
| `input.add` | `{kind, name?, config}` | Cria fonte; devolve `{inputId}`. `kind` ∈ `synthetic, media, image, title, camera, screen, ndi, srt, decklink`. |
| `input.update` | `{inputId, config}` | Configuração parcial (formato, fit, cor, atraso, modo low-bandwidth). |
| `input.remove` | `{inputId}` | — |
| `input.reorder` | `{order:[inputId]}` | Ordem na barra de fontes. |
| `media.play` / `media.pause` / `media.stop` | `{inputId}` | Transporte de ficheiros. |
| `media.seek` | `{inputId, seconds}` | — |
| `media.setLoop` | `{inputId, loop, inSeconds?, outSeconds?}` | — |
| `title.setFields` | `{inputId, fields:{name:value}}` | Texto dos títulos CoreText. |
| `switcher.setPreview` | `{inputId}` | — |
| `switcher.cut` | `{}` | Troca Program/Preview no próximo tick. |
| `switcher.transition` | `{kind:"fade"\|"wipe"\|"dip"\|"stinger", durationFrames, wipe?:{direction, softness}, colour?}` | Auto-transição. |
| `switcher.tbar` | `{position:0..1}` | ≤ 60 Hz; `1.0` conclui. |
| `switcher.ftb` | `{on}` | Fade to black com rampa de áudio. |
| `overlay.set` | `{slot:1..4, inputId?, on, rect?, crop?, opacity?, border?, transition?:{kind, durationFrames}}` | Overlay. `inputId: null` limpa o slot. |
| `audio.setGain` | `{inputId\|"master", db}` | — |
| `audio.setMute` / `audio.setSolo` / `audio.setAFV` | `{inputId, on}` | — |
| `audio.setDelay` | `{inputId, ms}` | ±500 ms. |
| `audio.setPan` | `{inputId, pan:-1..1}` | — |
| `audio.setMonitor` | `{deviceId?, db?, bus?}` | Dispositivo e barramento ("master", "a", "b") de monitorização. |
| `audio.setBus` | `{inputId, bus:"master"\|"a"\|"b", on}` | Envio do canal para um barramento. |
| `audio.setOutputBus` | `{target:"stream"\|"ndi", bus}` | Barramento que alimenta stream/gravação ou NDI. |
| `audio.addPlugin` | `{inputId, componentId}` | Instancia um Audio Unit (id de `devices.audioUnits`); devolve `{pluginId}`. |
| `audio.removePlugin` / `audio.setPluginBypass` | `{inputId, pluginId, on?}` | — |
| `audio.openPluginUI` | `{inputId, pluginId}` | Abre a janela de parâmetros do plugin no motor. |
| `project.list` | `{}` | Nomes dos projectos em `projects/`. |
| `record.setFolder` | `{folder\|null, container?}` | Pasta e formato de gravação (persistidos). |
| `output.add` | `{kind:"rtmp"\|"srt"\|"ndi", name, config}` | Config RTMP: `{url, streamKey}` (chave guardada no Keychain, nunca devolvida). |
| `output.update` / `output.remove` | `{outputId, config?}` | — |
| `output.start` / `output.stop` | `{outputId, txnId}` | — |
| `record.start` | `{profileId?, folder?, container:"mov"\|"mp4", txnId}` | — |
| `record.stop` | `{txnId}` | — |
| `projector.set` | `{displayId\|null, source:"program"\|"multiview"\|inputId, fullscreen}` | `null` fecha. |
| `project.setRaster` | `{width, height, fps:25\|29.97\|30\|50\|59.94\|60}` | Só com saídas paradas; recria pools. |
| `project.save` / `project.load` | `{path}` | Projecto completo em JSON. |
| `preview.keyframe` | `{stream}` | Força IDR. |
| `preview.setLayout` | `{layoutId}` | Layout do multiview (`2+8`, `2+16`, `pgm+pvw`). |
| `devices.refresh` | `{}` | Re-enumera. |
| `permissions.status` / `permissions.request` | `{kind:"camera"\|"microphone"\|"screen"\|"localNetwork"}` | — |
| `engine.shutdown` | `{force?}` | Recusa se há saídas no ar e `force` ausente. |

## 4. Estado (`EngineState`)

Tipos em estilo TypeScript. Tudo o que muda devagar e que um cliente ao reconectar precisa de ver. Telemetria rápida fica em `stats` e nos frames binários.

```ts
interface EngineState {
  rev: number;
  project: { name: string; raster: { width: number; height: number; fps: 25|29.97|30|50|59.94|60 }; path?: string };
  inputs: Record<InputId, InputState>;
  inputOrder: InputId[];
  program: { inputId: InputId|null; transition: TransitionState|null; ftb: boolean };
  preview: { inputId: InputId|null };
  overlays: [OverlaySlot, OverlaySlot, OverlaySlot, OverlaySlot];
  audio: { inputs: Record<InputId, AudioChannelState>; master: { db: number; mute: boolean; limiter: boolean }; monitor: { deviceId: string|null; db: number; bus: "master"|"a"|"b" }; outputBus: { stream: "master"|"a"|"b"; ndi: "master"|"a"|"b" } };
  outputs: Record<OutputId, OutputState>;
  recording: { status: "idle"|"starting"|"recording"|"stopping"; file?: string; startedAt?: string; bytes?: number; container: "mov"|"mp4" };
  projector: { displayId: string|null; source: "program"|"multiview"|InputId; fullscreen: boolean };
  multiview: { layoutId: string; size: { width: number; height: number }; tiles: Tile[] };
  devices: { video: VideoDevice[]; audioIn: AudioDevice[]; audioOut: AudioDevice[]; displays: Display[]; ndiSources: NdiSource[]; audioUnits: { id: string; name: string; manufacturer: string }[] };
  permissions: Record<"camera"|"microphone"|"screen"|"localNetwork", "granted"|"denied"|"notDetermined"|"unknown">;
  budget: { encoderCapacity1080pFps: number; encoderUsedPercent: number; memoryUsedMB: number; memoryLimitMB: number };
  alarms: Alarm[];
  system: { engineVersion: string; pid: number; startedAt: string; bind: string; remoteAccess: boolean; thermal: "nominal"|"fair"|"serious"|"critical" };
}

type InputId = string;   // "in_" + 6 caracteres
type OutputId = string;  // "out_" + 6 caracteres

interface InputState {
  id: InputId;
  kind: "synthetic"|"media"|"image"|"title"|"camera"|"screen"|"ndi"|"srt"|"decklink";
  name: string;
  status: "idle"|"starting"|"live"|"noSignal"|"error";
  statusCode?: string;
  format?: { width: number; height: number; fps: number; pixelFormat: "nv12"|"bgra"|"uyvy"|"v210" };
  latencyFrames: number;
  videoDelayFrames: number;
  fit: "fit"|"fill"|"stretch"|"crop";
  colour: { brightness: number; contrast: number; saturation: number };
  lowBandwidth: boolean;
  config: SyntheticConfig|MediaConfig|ImageConfig|TitleConfig|CameraConfig|ScreenConfig|NdiConfig|SrtConfig|DeckLinkConfig;
  media?: { durationSeconds: number; positionSeconds: number; state: "stopped"|"playing"|"paused"; loop: boolean; inSeconds?: number; outSeconds?: number };
  hasAudio: boolean;
}

interface SyntheticConfig { pattern: "colour"|"bars"|"testPattern"|"sync"; colour?: string; tone?: boolean }
interface MediaConfig { path: string; speed: number }
interface ImageConfig { path?: string }                    // ou PNG enviado por PUT
interface TitleConfig { template: string; fields: Record<string, string> }
interface CameraConfig { uniqueId: string; formatIndex?: number; audio: boolean }
interface ScreenConfig { displayId?: string; windowId?: number; audio: boolean; showCursor: boolean }
interface NdiConfig { sourceName: string; bandwidth: "highest"|"lowest" }
interface SrtConfig { url: string; mode?: "caller"|"listener"; latencyMs?: number; passphrase?: string; streamId?: string }  // srt://:porta = listener, srt://host:porta = caller
interface DeckLinkConfig { deviceIndex: number; mode?: string }

interface TransitionState { kind: "cut"|"fade"|"wipe"|"dip"|"stinger"; durationFrames: number; progress: number; auto: boolean; wipe?: { direction: "left"|"right"|"up"|"down"|"box"|"circle"|"diagonalUp"|"diagonalDown"; softness: number }; colour?: string }

interface OverlaySlot { inputId: InputId|null; on: boolean; rect: Rect; crop: Rect; opacity: number; border: { width: number; colour: string }|null; transition: { kind: "cut"|"fade"|"slide"; durationFrames: number } }
interface Rect { x: number; y: number; w: number; h: number }   // normalizado 0..1

interface AudioChannelState { db: number; mute: boolean; solo: boolean; afv: boolean; pan: number; delayMs: number; channels: 1|2; buses: ("master"|"a"|"b")[]; plugins: { id: string; componentId: string; name: string; bypass: boolean }[] }

interface OutputState {
  id: OutputId; kind: "rtmp"|"srt"|"ndi"; name: string;
  status: "stopped"|"starting"|"live"|"reconnecting"|"error"; statusCode?: string;
  profileId: string;                                       // perfil de codificação partilhado
  config: { url?: string; hasStreamKey?: boolean; ndiName?: string; latencyMs?: number };
  autoRestart: boolean; startedAt?: string;
}

interface Tile { source: "program"|"preview"|InputId; rect: Rect; label: string }
interface VideoDevice { uniqueId: string; name: string; kind: "builtin"|"usb"|"continuity"|"virtual"; formats: { width: number; height: number; fps: number[]; pixelFormat: string }[] }
interface AudioDevice { uid: string; name: string; channels: number; sampleRate: number; isDefault: boolean }
interface Display { id: string; name: string; width: number; height: number; refreshHz: number; isMain: boolean }
interface NdiSource { name: string; url: string }
interface Alarm { id: string; code: string; level: "warning"|"critical"; at: string; detail?: string }
```

Regras: o motor é a única fonte de verdade; a UI só guarda localmente valores optimistas de sliders (T-bar, ganhos) e reconcilia ao receber o patch. O snapshot fica abaixo de 100 KB.

## 5. Preview binário (`/ws/preview`)

Cada mensagem WebSocket binária é um cabeçalho de 24 bytes (little-endian) seguido do payload:

| Offset | Tamanho | Campo |
|---|---|---|
| 0 | 4 | magic `"WTVF"` |
| 4 | 1 | `version` = 1 |
| 5 | 1 | `streamId`: 1 multiview, 2 program, 3–15 reservados, 16 VU, 17 posições de media |
| 6 | 1 | `flags`: bit0 keyframe, bit1 contém `avcC` (config), bit2 descontinuidade |
| 7 | 1 | `codec`: 1 avc1, 2 hvc1, 3 jpeg, 0 não-vídeo |
| 8 | 4 | `seq` u32 |
| 12 | 8 | `ptsMicros` u64 (host time) |
| 20 | 4 | `payloadLen` u32 |
| 24 | n | payload |

Vídeo: payload = access unit em AVCC (NALs com prefixo de comprimento de 4 bytes) tal como o VideoToolbox emite. Com bit1 ligado o payload começa por `u16 configLen` + `avcC` e só depois os NALs; o `avcC` vai em todos os keyframes para que um cliente tardio configure o descodificador logo no primeiro.

Codificador: H.264 High, `RealTime`, `AllowFrameReordering=false`, `EnableLowLatencyRateControl`, IDR a cada 2 s e a pedido (`preview.keyframe`). Multiview 1280×720@30 ≈ 4–6 Mbps; Program 640×360@30 ≈ 1 Mbps.

Cliente: `VideoDecoder.configure({codec:"avc1.640028", description: avcC, optimizeForLatency: true, hardwareAcceleration: "no-preference"})` num Worker; frames desenhados num `<canvas>` e fechados de imediato; tiles recortados com `drawImage(frame, sx, sy, sw, sh, …)` usando `state.multiview.tiles`. Em lacuna de `seq` o cliente espera o próximo keyframe. O motor descarta frames (mantém keyframes) para clientes cujo buffer passe de 500 ms.

VU (`streamId` 16, 20 Hz): payload = `u16 count` seguido de `count × {u8 inputIndex, f16 peakL, f16 peakR, f16 rmsL, f16 rmsR}`. O índice refere `state.inputOrder`; 255 = Master, 254 = Bus A, 253 = Bus B.

Posições de media (`streamId` 17, 10 Hz): `u16 count` + `count × {u8 inputIndex, f32 positionSeconds}`.

## 6. Ficheiros no disco

`~/Library/Application Support/WTV Studio/`

| Ficheiro | Conteúdo |
|---|---|
| `engine.json` (0600) | `{pid, port, token, version, startedAt, bench?}` |
| `engine.lock` | flock de instância única |
| `session.json` | último `EngineState` sem telemetria; restaurado no arranque |
| `projects/*.wtv.json` | projectos guardados |
| `~/Library/Logs/WTV Studio/engine.log` | registo (stdout não é capturado sob `open`) |

## 7. Versão

`session.hello` devolve `protocolVersion: 1`. Alterações incompatíveis incrementam a versão; a UI recusa ligar a versões maiores e mostra "Actualize o WTV Studio".

## Acrescentos do motor libobs (2026-10-23)

- `audio.getPluginParams {inputId, pluginId}` → `{properties: [{name, description, type: float|int|bool|text|list, min?, max?, step?, options?: [{name, value}]}], values: {…}}`
  (propriedades do filtro da libobs; `audio.openPluginUI` devolve o mesmo porque os filtros não têm janela própria).
- `audio.setPluginParam {inputId, pluginId, params: {nome: valor}}` aplica os valores ao filtro.
- `projector.set` aceita `source` = `"program"`, `"multiview"` ou um `inputId`; `fullscreen` é ignorado no ecrã principal.
- `project.setEncoding {videoBitrateKbps?, audioBitrateKbps?, keyintSec?, profile?, rateControl?}` altera `project.encoding`
  (codificação de Program partilhada por stream e gravação); recusado com `ALREADY_RUNNING` enquanto houver saídas ou gravação activas.
- Playout (motor libobs): fonte `kind: "playlist"` com `config {items: [{path, name, in, out, duration?}], index, loopList, channel?, date?}`;
  comandos `playlist.add {inputId, paths}`, `playlist.remove {inputId, index}`, `playlist.move {inputId, from, to}`, `playlist.jump {inputId, index}`,
  `playlist.next {inputId}`, `playlist.setLoop {inputId, on}`, `playlist.setItem {inputId, index, in?, out?, name?}`,
  `playlist.import {inputId, path}` / `playlist.export {inputId, path}` no formato do ffplayout (`channel`, `date`, `program[{in,out,duration,source}]`).
  Quando um ficheiro acaba (`media_ended`) ou chega ao `out`, passa ao seguinte; o salto ao `in` cai no keyframe anterior (precisão = GOP do ficheiro).
- Entradas de áudio: `input.add {kind: "audioDevice", config: {uid}}` (coreaudio_input_capture; `devices.audioIn` lista os dispositivos, `uid: "default"` = predefinido).
- `audio.setTuning {on, cents}` (motor libobs): afinação global; liga um filtro de pitch oculto em todos os canais (actuais e futuros); estado em `audio.tuning {enabled, cents}`.
