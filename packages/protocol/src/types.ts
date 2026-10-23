// Tipos do estado e das mensagens. Espelho de docs/PROTOCOLO.md e de engine/Sources/WTVProtocol.
// Identificadores em inglês; comentários em português.

export const PROTOCOL_VERSION = 1;
export const DEFAULT_PORT = 7420;

export type InputId = string;
export type OutputId = string;

export type FrameRate = 25 | 29.97 | 30 | 50 | 59.94 | 60;

/** Codificação de Program partilhada por stream e gravação (motor libobs). */
export interface EncodingSettings {
  videoBitrateKbps: number;
  audioBitrateKbps: number;
  keyintSec: number;
  profile: "baseline" | "main" | "high";
  rateControl: "CBR" | "VBR";
}
export interface Raster {
  width: number;
  height: number;
  fps: FrameRate;
}

export interface EngineState {
  rev: number;
  project: { name: string; raster: Raster; path?: string; encoding?: EncodingSettings };
  inputs: Record<InputId, InputState>;
  inputOrder: InputId[];
  program: { inputId: InputId | null; transition: TransitionState | null; ftb: boolean };
  preview: { inputId: InputId | null };
  overlays: [OverlaySlot, OverlaySlot, OverlaySlot, OverlaySlot];
  audio: {
    inputs: Record<InputId, AudioChannelState>;
    master: { db: number; mute: boolean; limiter: boolean };
    monitor: { deviceId: string | null; db: number; bus: AudioBus };
    outputBus: Record<"stream" | "ndi", AudioBus>;
    /** Afinação global (motor libobs): filtro de pitch em todos os canais; −31,77 cents = 432 Hz. */
    tuning?: { enabled: boolean; cents: number };
  };
  outputs: Record<OutputId, OutputState>;
  recording: RecordingState;
  /** Replay instantâneo (motor libobs, plugin Replay Source); ausente = motor sem suporte de replay. */
  replay?: ReplayState;
  projector: { displayId: string | null; source: "program" | "multiview" | InputId; fullscreen: boolean };
  multiview: { layoutId: string; size: { width: number; height: number }; tiles: Tile[] };
  devices: {
    video: VideoDevice[];
    audioIn: AudioDevice[];
    audioOut: AudioDevice[];
    displays: Display[];
    ndiSources: NdiSource[];
    audioUnits: AudioUnitDevice[];
  };
  permissions: Record<PermissionKind, PermissionStatus>;
  budget: {
    encoderCapacity1080pFps: number;
    encoderUsedPercent: number;
    memoryUsedMB: number;
    memoryLimitMB: number;
  };
  alarms: Alarm[];
  system: {
    engineVersion: string;
    pid: number;
    startedAt: string;
    bind: string;
    remoteAccess: boolean;
    thermal: "nominal" | "fair" | "serious" | "critical";
  };
}

export type PermissionKind = "camera" | "microphone" | "screen" | "localNetwork";
export type PermissionStatus = "granted" | "denied" | "notDetermined" | "unknown";

export type InputKind =
  | "synthetic"
  | "media"
  | "image"
  | "title"
  | "playlist"
  | "audioDevice"
  | "camera"
  | "screen"
  | "ndi"
  | "srt"
  | "decklink"
  | "replay";

export type InputCategory = "cameras" | "vt" | "graphics" | "calls" | "audio";
export const INPUT_CATEGORIES: { id: InputCategory; label: string; colour: string }[] = [
  { id: "cameras", label: "Câmaras", colour: "#3b7dd8" },
  { id: "vt", label: "VT", colour: "#8e44ad" },
  { id: "graphics", label: "Gráficos", colour: "#e0a020" },
  { id: "calls", label: "Chamadas", colour: "#2ea043" },
  { id: "audio", label: "Áudio", colour: "#7f8c8d" },
];
/** Categoria por omissão a partir do tipo da fonte. */
export function defaultCategory(kind: InputKind): InputCategory {
  switch (kind) {
    case "camera": case "ndi": case "srt": case "decklink": case "screen": return "cameras";
    case "media": case "playlist": case "replay": return "vt";
    case "audioDevice": return "audio";
    default: return "graphics";
  }
}
export type InputStatus = "idle" | "starting" | "live" | "noSignal" | "error";

export interface InputState {
  id: InputId;
  kind: InputKind;
  name: string;
  status: InputStatus;
  statusCode?: string;
  /** Separador da faixa de fontes (cameras | vt | graphics | calls | audio); ausente = deduzido do kind. */
  category?: InputCategory;
  format?: { width: number; height: number; fps: number; pixelFormat: "nv12" | "bgra" | "uyvy" | "v210" };
  latencyFrames: number;
  videoDelayFrames: number;
  fit: "fit" | "fill" | "stretch" | "crop";
  colour: { brightness: number; contrast: number; saturation: number };
  lowBandwidth: boolean;
  config: InputConfig;
  media?: {
    durationSeconds: number;
    positionSeconds: number;
    state: "stopped" | "playing" | "paused";
    loop: boolean;
    inSeconds?: number;
    outSeconds?: number;
  };
  hasAudio: boolean;
}

export type InputConfig =
  | SyntheticConfig
  | MediaConfig
  | ImageConfig
  | TitleConfig
  | PlaylistConfig
  | AudioDeviceConfig
  | CameraConfig
  | ScreenConfig
  | NdiConfig
  | SrtConfig
  | DeckLinkConfig
  | ReplayConfig;

export interface SyntheticConfig {
  pattern: "colour" | "bars" | "testPattern" | "sync";
  colour?: string;
  tone?: boolean;
}
export interface MediaConfig {
  path: string;
  speed: number;
}
export interface ImageConfig {
  path?: string;
}
export interface TitleConfig {
  template: string;
  fields: Record<string, string>;
}
/** Playout: lista de reprodução encadeada; formato compatível com o ffplayout (in/out/duration/source). */
export interface PlaylistItem {
  path: string;
  name: string;
  in: number;
  out: number;
  duration?: number;
}
export interface PlaylistConfig {
  items: PlaylistItem[];
  index: number;
  loopList: boolean;
  channel?: string;
  date?: string;
}
/** Entrada de áudio (microfone / interface) sem vídeo. */
export interface AudioDeviceConfig {
  uid: string;
}
export interface CameraConfig {
  uniqueId: string;
  formatIndex?: number;
  audio: boolean;
}
export interface ScreenConfig {
  displayId?: string;
  windowId?: number;
  audio: boolean;
  showCursor: boolean;
}
export interface NdiConfig {
  sourceName: string;
  bandwidth: "highest" | "lowest";
}
export interface SrtConfig {
  url: string;
  mode: "caller" | "listener";
  latencyMs: number;
}
export interface DeckLinkConfig {
  deviceIndex: number;
  mode?: string;
}
/** Fonte "Replay" (motor libobs, plugin Replay Source): sem parâmetros próprios; o estado vive em EngineState.replay. */
export interface ReplayConfig {}

export type TransitionKind = "cut" | "fade" | "wipe" | "dip" | "stinger";
export type WipeDirection =
  | "left"
  | "right"
  | "up"
  | "down"
  | "box"
  | "circle"
  | "diagonalUp"
  | "diagonalDown";

export interface TransitionState {
  kind: TransitionKind;
  durationFrames: number;
  progress: number;
  auto: boolean;
  wipe?: { direction: WipeDirection; softness: number };
  colour?: string;
}

export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface OverlaySlot {
  inputId: InputId | null;
  on: boolean;
  rect: Rect;
  crop: Rect;
  opacity: number;
  border: { width: number; colour: string } | null;
  transition: { kind: "cut" | "fade" | "slide"; durationFrames: number };
}

export type AudioBus = "master" | "a" | "b";

export interface AudioPluginState {
  id: string;
  componentId: string;
  name: string;
  bypass: boolean;
}

export interface AudioChannelState {
  db: number;
  mute: boolean;
  solo: boolean;
  afv: boolean;
  pan: number;
  delayMs: number;
  channels: 1 | 2;
  /** Barramentos a que o canal envia. */
  buses: AudioBus[];
  /** Cadeia de plugins Audio Unit. */
  plugins: AudioPluginState[];
}

export interface AudioUnitDevice {
  id: string;
  name: string;
  manufacturer: string;
}

export type OutputKind = "rtmp" | "srt" | "ndi";
export type OutputStatus = "stopped" | "starting" | "live" | "reconnecting" | "error";

export interface OutputState {
  id: OutputId;
  kind: OutputKind;
  name: string;
  status: OutputStatus;
  statusCode?: string;
  profileId: string;
  config: { url?: string; hasStreamKey?: boolean; ndiName?: string; latencyMs?: number };
  autoRestart: boolean;
  startedAt?: string;
}

export interface RecordingState {
  status: "idle" | "starting" | "recording" | "stopping";
  file?: string;
  startedAt?: string;
  bytes?: number;
  container: "mov" | "mp4";
  /** Pasta de destino; ausente = ~/Movies/WTV Studio. */
  folder?: string | null;
  /** MultiCorder (motor libobs): gravações ISO por fonte em curso. */
  iso?: Record<InputId, { status: "recording" | "stopping" | "idle" | "error"; file: string; startedAt: string; track: number }>;
}

/** Replay instantâneo: buffers por ângulo (filtros de replay) e uma fonte "Replay" que toca o lance capturado. */
export interface ReplayState {
  /** Duração do buffer por ângulo, em segundos (omissão 8, 1..30). */
  bufferSeconds: number;
  /** inputIds armados (têm filtro de replay). */
  angles: InputId[];
  /** id do input "Replay" (kind "replay"), criado pelo motor quando há ângulos. */
  inputId: InputId | null;
  /** Ângulo do último lance carregado. */
  loadedAngle: InputId | null;
  /** Velocidade de reprodução em percentagem: 25 | 50 | 100 (ou outra, 1..400). */
  speedPercent: number;
  paused: boolean;
  /** O input Replay está em Program (replay.onAir). */
  onAir: boolean;
  /** Input que estava em Program antes de replay.onAir (para voltar ao vivo). */
  liveInput: InputId | null;
  /** Estimativa da RAM usada pelos buffers (bufferSeconds × ângulos × raster). */
  memoryMB: number;
  /** unavailable = plugin Replay Source não carregado. */
  status: "idle" | "buffering" | "loaded" | "unavailable";
}

export interface Tile {
  source: "program" | "preview" | InputId;
  rect: Rect;
  label: string;
}

export interface VideoDevice {
  uniqueId: string;
  name: string;
  kind: "builtin" | "usb" | "continuity" | "virtual";
  formats: { width: number; height: number; fps: number[]; pixelFormat: string }[];
}
export interface AudioDevice {
  uid: string;
  name: string;
  channels: number;
  sampleRate: number;
  isDefault: boolean;
}
export interface Display {
  id: string;
  name: string;
  width: number;
  height: number;
  refreshHz: number;
  isMain: boolean;
}
export interface NdiSource {
  name: string;
  url: string;
}
export interface Alarm {
  id: string;
  code: string;
  level: "warning" | "critical";
  at: string;
  detail?: string;
}

// ---- JSON-RPC 2.0 -------------------------------------------------------

export type RpcId = number | string;

export interface RpcRequest<P = unknown> {
  jsonrpc: "2.0";
  id: RpcId;
  method: string;
  params?: P;
}

export interface RpcNotification<P = unknown> {
  jsonrpc: "2.0";
  method: string;
  params?: P;
}

export interface RpcSuccess<R = unknown> {
  jsonrpc: "2.0";
  id: RpcId;
  result: R;
}

export interface RpcError {
  jsonrpc: "2.0";
  id: RpcId | null;
  error: { code: number; message: string; data?: { code: DomainErrorCode; detail?: string } };
}

export type RpcMessage = RpcRequest | RpcNotification | RpcSuccess | RpcError;

export type DomainErrorCode =
  | "INPUT_NOT_FOUND"
  | "OUTPUT_NOT_FOUND"
  | "INVALID_PARAMS"
  | "ENCODER_BUDGET"
  | "MEMORY_BUDGET"
  | "DEVICE_UNAVAILABLE"
  | "PERMISSION_DENIED"
  | "ALREADY_RUNNING"
  | "NOT_RUNNING"
  | "DISK_FULL"
  | "CAPABILITY_MISSING"
  | "UNAUTHORIZED"
  | "ROLE_FORBIDDEN"
  | "METHOD_NOT_FOUND";

export const RPC_DOMAIN_ERROR = -32000;

// Notificações motor → cliente
export interface SnapshotParams {
  rev: number;
  state: EngineState;
}
export interface PatchParams {
  fromRev: number;
  toRev: number;
  ops: PatchOp[];
}
export interface StatsParams {
  inputs: Record<InputId, { fps: number; dropped: number; repeated: number }>;
  outputs: Record<OutputId, { bitrateKbps: number; rttMs: number; reconnects: number; droppedFrames: number }>;
  system: {
    cpu: number;
    rssMB: number;
    gpuMs: number;
    encoderPercent: number;
    thermal: string;
    lateFrames: number;
  };
}
export interface LogParams {
  level: "debug" | "info" | "warning" | "error";
  code: string;
  message: string;
  at: string;
}

export interface HelloParams {
  clientKind: "electron" | "browser";
  clientName: string;
  lastRev?: number;
}
export interface HelloResult {
  protocolVersion: number;
  engineVersion: string;
  capabilities: Capabilities;
  snapshot: SnapshotParams;
}
export interface Capabilities {
  ndi: boolean;
  srt: boolean;
  decklink: boolean;
  metalRuntimeShaders: boolean;
}

// ---- JSON Patch (RFC 6902, subconjunto) ---------------------------------

export type PatchOp =
  | { op: "add"; path: string; value: unknown }
  | { op: "replace"; path: string; value: unknown }
  | { op: "remove"; path: string };
