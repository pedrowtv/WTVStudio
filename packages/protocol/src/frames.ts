// Cabeçalho binário do preview (docs/PROTOCOLO.md §5). 24 bytes, little-endian.

export const FRAME_MAGIC = 0x46565457; // "WTVF" lido como u32 LE a partir dos bytes 'W','T','V','F'
export const FRAME_HEADER_SIZE = 24;
export const FRAME_VERSION = 1;

export const StreamId = {
  multiview: 1,
  program: 2,
  meters: 16,
  mediaPositions: 17,
} as const;

export const FrameFlag = {
  keyframe: 1 << 0,
  hasConfig: 1 << 1,
  discontinuity: 1 << 2,
} as const;

export const FrameCodec = {
  none: 0,
  avc1: 1,
  hvc1: 2,
  jpeg: 3,
} as const;

export interface FrameHeader {
  version: number;
  streamId: number;
  flags: number;
  codec: number;
  seq: number;
  ptsMicros: bigint;
  payloadLen: number;
}

export function encodeFrameHeader(h: FrameHeader): Uint8Array {
  const buf = new ArrayBuffer(FRAME_HEADER_SIZE);
  const view = new DataView(buf);
  view.setUint8(0, 0x57); // W
  view.setUint8(1, 0x54); // T
  view.setUint8(2, 0x56); // V
  view.setUint8(3, 0x46); // F
  view.setUint8(4, h.version);
  view.setUint8(5, h.streamId);
  view.setUint8(6, h.flags);
  view.setUint8(7, h.codec);
  view.setUint32(8, h.seq, true);
  view.setBigUint64(12, h.ptsMicros, true);
  view.setUint32(20, h.payloadLen, true);
  return new Uint8Array(buf);
}

export function decodeFrameHeader(data: ArrayBuffer | Uint8Array): FrameHeader {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  if (bytes.byteLength < FRAME_HEADER_SIZE) throw new Error("frame demasiado curto");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (bytes[0] !== 0x57 || bytes[1] !== 0x54 || bytes[2] !== 0x56 || bytes[3] !== 0x46) {
    throw new Error("magic inválido");
  }
  const h: FrameHeader = {
    version: view.getUint8(4),
    streamId: view.getUint8(5),
    flags: view.getUint8(6),
    codec: view.getUint8(7),
    seq: view.getUint32(8, true),
    ptsMicros: view.getBigUint64(12, true),
    payloadLen: view.getUint32(20, true),
  };
  if (h.version !== FRAME_VERSION) throw new Error(`versão de frame ${h.version} não suportada`);
  if (FRAME_HEADER_SIZE + h.payloadLen > bytes.byteLength) throw new Error("payload truncado");
  return h;
}

/** Separa um frame de vídeo em descrição do codec (avcC, opcional) e access unit AVCC. */
export function splitVideoPayload(
  header: FrameHeader,
  message: Uint8Array,
): { config: Uint8Array | null; accessUnit: Uint8Array } {
  let offset = FRAME_HEADER_SIZE;
  const end = FRAME_HEADER_SIZE + header.payloadLen;
  let config: Uint8Array | null = null;
  if (header.flags & FrameFlag.hasConfig) {
    const view = new DataView(message.buffer, message.byteOffset, message.byteLength);
    const configLen = view.getUint16(offset, true);
    offset += 2;
    config = message.subarray(offset, offset + configLen);
    offset += configLen;
  }
  return { config, accessUnit: message.subarray(offset, end) };
}

export interface MeterReading {
  inputIndex: number; // 255 = master
  peakL: number;
  peakR: number;
  rmsL: number;
  rmsR: number;
}

/** Descodifica o payload de VU (streamId 16): u16 count + count × {u8, f16×4}. */
export function decodeMeters(header: FrameHeader, message: Uint8Array): MeterReading[] {
  const view = new DataView(message.buffer, message.byteOffset, message.byteLength);
  let offset = FRAME_HEADER_SIZE;
  const declared = view.getUint16(offset, true);
  offset += 2;
  const count = Math.min(declared, Math.floor((header.payloadLen - 2) / 9));
  const out: MeterReading[] = [];
  for (let i = 0; i < count; i++) {
    out.push({
      inputIndex: view.getUint8(offset),
      peakL: readFloat16(view, offset + 1),
      peakR: readFloat16(view, offset + 3),
      rmsL: readFloat16(view, offset + 5),
      rmsR: readFloat16(view, offset + 7),
    });
    offset += 9;
  }
  return out;
}

export function readFloat16(view: DataView, offset: number): number {
  const h = view.getUint16(offset, true);
  const sign = h & 0x8000 ? -1 : 1;
  const exp = (h >> 10) & 0x1f;
  const frac = h & 0x3ff;
  if (exp === 0) return sign * frac * 2 ** -24;
  if (exp === 0x1f) return frac ? NaN : sign * Infinity;
  return sign * (1 + frac / 1024) * 2 ** (exp - 15);
}
