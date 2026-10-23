// Descodificador do preview: /ws/preview → WebCodecs VideoDecoder → canvas (docs/PROTOCOLO.md §5).
import {
  FrameCodec,
  FrameFlag,
  StreamId,
  decodeFrameHeader,
  decodeMeters,
  splitVideoPayload,
  type MeterReading,
} from "@wtv/protocol";

export interface PreviewOptions {
  baseUrl: string;
  token: string | null;
  stream: "multiview" | "program";
  /** Canvas de destino (opcional quando se usa onFrame). */
  canvas?: HTMLCanvasElement;
  /** Recebe cada frame descodificado; quem o recebe tem de o fechar. */
  onFrame?: (frame: VideoFrame) => void;
  onMeters?: (m: MeterReading[]) => void;
  onStatus?: (s: string) => void;
}

export class PreviewClient {
  private ws: WebSocket | null = null;
  private decoder: VideoDecoder | null = null;
  private ctx: CanvasRenderingContext2D | null = null;
  private configured = false;
  private waitingKeyframe = true;
  private lastSeq = -1;
  private closed = false;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private lastConfig: Uint8Array | null = null;

  constructor(private opts: PreviewOptions) {
    if (opts.canvas) this.ctx = opts.canvas.getContext("2d", { alpha: false });
  }

  static supported(): boolean {
    return typeof VideoDecoder !== "undefined";
  }

  connect(): void {
    this.closed = false;
    this.open();
  }

  private open(): void {
    if (this.closed) return;
    const u = new URL(this.opts.baseUrl);
    u.protocol = u.protocol === "https:" ? "wss:" : "ws:";
    u.pathname = "/ws/preview";
    u.searchParams.set("stream", this.opts.stream);
    if (this.opts.token) u.searchParams.set("token", this.opts.token);
    const ws = new WebSocket(u);
    ws.binaryType = "arraybuffer";
    this.ws = ws;
    ws.onopen = () => this.opts.onStatus?.("ligado");
    ws.onmessage = (ev) => this.onMessage(new Uint8Array(ev.data as ArrayBuffer));
    ws.onclose = () => {
      this.opts.onStatus?.("desligado");
      this.resetDecoder();
      if (!this.closed) this.reconnectTimer = setTimeout(() => this.open(), 1000);
    };
  }

  close(): void {
    this.closed = true;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.ws?.close();
    this.resetDecoder();
  }

  private resetDecoder(): void {
    try {
      this.decoder?.close();
    } catch {
      /* já fechado */
    }
    this.decoder = null;
    this.configured = false;
    this.waitingKeyframe = true;
    this.lastSeq = -1;
    this.lastConfig = null;
  }

  private onMessage(bytes: Uint8Array): void {
    let header;
    try {
      header = decodeFrameHeader(bytes);
    } catch (e) {
      console.warn("frame inválido", e);
      return;
    }
    if (header.streamId === StreamId.meters) {
      try {
        this.opts.onMeters?.(decodeMeters(header, bytes));
      } catch (e) {
        console.warn("VU inválido", e);
      }
      return;
    }
    if (header.codec !== FrameCodec.avc1) return;

    if (this.lastSeq >= 0 && header.seq !== this.lastSeq + 1) this.waitingKeyframe = true;
    if (header.flags & FrameFlag.discontinuity) this.waitingKeyframe = true;
    this.lastSeq = header.seq;
    const isKey = (header.flags & FrameFlag.keyframe) !== 0;
    if (this.waitingKeyframe && !isKey) return;

    const { config, accessUnit } = splitVideoPayload(header, bytes);
    if (config && this.configured && this.lastConfig && !sameBytes(config, this.lastConfig)) {
      // novo SPS/PPS (mudou a resolução do multiview): reconfigura
      this.resetDecoder();
    }
    if (!this.configured) {
      if (!config || config.length < 7) return;
      this.configure(config);
      this.lastConfig = config.slice();
    }
    if (!this.decoder || this.decoder.state !== "configured") return;
    this.waitingKeyframe = false;
    this.decoder.decode(
      new EncodedVideoChunk({
        type: isKey ? "key" : "delta",
        timestamp: Number(header.ptsMicros),
        data: accessUnit,
      }),
    );
  }

  private configure(avcC: Uint8Array): void {
    const profile = avcC[1].toString(16).padStart(2, "0");
    const compat = avcC[2].toString(16).padStart(2, "0");
    const level = avcC[3].toString(16).padStart(2, "0");
    const codec = `avc1.${profile}${compat}${level}`;
    const decoder = new VideoDecoder({
      output: (frame) => this.draw(frame),
      error: (e) => {
        console.error("VideoDecoder", e);
        this.resetDecoder();
      },
    });
    decoder.configure({
      codec,
      description: avcC,
      optimizeForLatency: true,
      hardwareAcceleration: "no-preference",
    });
    this.decoder = decoder;
    this.configured = true;
  }

  private draw(frame: VideoFrame): void {
    if (this.opts.onFrame) {
      this.opts.onFrame(frame);
      return;
    }
    try {
      const c = this.opts.canvas;
      if (c && this.ctx) {
        if (c.width !== frame.displayWidth || c.height !== frame.displayHeight) {
          c.width = frame.displayWidth;
          c.height = frame.displayHeight;
        }
        this.ctx.drawImage(frame, 0, 0);
      }
    } finally {
      frame.close();
    }
  }
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
