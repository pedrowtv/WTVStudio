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
  };
  outputs: Record<OutputId, OutputState>;
  recording: RecordingState;
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
  | "camera"
  | "screen"
  | "ndi"
  | "srt"
  | "decklink";

export type InputStatus = "idle" | "starting" | "live" | "noSignal" | "error";

export interface InputState {
  id: InputId;
  kind: InputKind;
  name: string;
  status: InputStatus;
  statusCode?: string;
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
  | CameraConfig
  | ScreenConfig
  | NdiConfig
  | SrtConfig
  | DeckLinkConfig;

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
