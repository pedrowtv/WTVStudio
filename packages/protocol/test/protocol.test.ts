import { describe, expect, it } from "vitest";
import {
  FRAME_HEADER_SIZE,
  FrameCodec,
  FrameFlag,
  StreamId,
  applyPatch,
  decodeFrameHeader,
  encodeFrameHeader,
  splitVideoPayload,
} from "../src";

describe("cabeçalho binário", () => {
  it("codifica e descodifica sem perdas", () => {
    const header = {
      version: 1,
      streamId: StreamId.multiview,
      flags: FrameFlag.keyframe | FrameFlag.hasConfig,
      codec: FrameCodec.avc1,
      seq: 123456,
      ptsMicros: 1234567890123n,
      payloadLen: 10,
    };
    const bytes = encodeFrameHeader(header);
    expect(bytes.byteLength).toBe(FRAME_HEADER_SIZE);
    const full = new Uint8Array(FRAME_HEADER_SIZE + 10);
    full.set(bytes, 0);
    expect(decodeFrameHeader(full)).toEqual(header);
  });

  it("separa avcC do access unit", () => {
    const config = new Uint8Array([1, 2, 3]);
    const au = new Uint8Array([9, 9, 9, 9]);
    const payloadLen = 2 + config.length + au.length;
    const header = {
      version: 1,
      streamId: 1,
      flags: FrameFlag.hasConfig,
      codec: 1,
      seq: 1,
      ptsMicros: 0n,
      payloadLen,
    };
    const msg = new Uint8Array(FRAME_HEADER_SIZE + payloadLen);
    msg.set(encodeFrameHeader(header), 0);
    msg[FRAME_HEADER_SIZE] = config.length;
    msg[FRAME_HEADER_SIZE + 1] = 0;
    msg.set(config, FRAME_HEADER_SIZE + 2);
    msg.set(au, FRAME_HEADER_SIZE + 2 + config.length);
    const parts = splitVideoPayload(header, msg);
    expect(Array.from(parts.config!)).toEqual([1, 2, 3]);
    expect(Array.from(parts.accessUnit)).toEqual([9, 9, 9, 9]);
  });

  it("rejeita magic inválido", () => {
    expect(() => decodeFrameHeader(new Uint8Array(24))).toThrow();
  });
});

describe("JSON Patch", () => {
  it("aplica add/replace/remove de forma imutável", () => {
    const before = { a: { b: 1 }, list: [1, 2], keep: { x: 1 } };
    const after = applyPatch(before, [
      { op: "replace", path: "/a/b", value: 2 },
      { op: "add", path: "/list/-", value: 3 },
      { op: "remove", path: "/list/0" },
      { op: "add", path: "/c", value: "novo" },
    ]);
    expect(after).toEqual({ a: { b: 2 }, list: [2, 3], keep: { x: 1 }, c: "novo" });
    expect(before.a.b).toBe(1);
    expect((after as typeof before).keep).toBe(before.keep);
  });

  it("descodifica ~0 e ~1 nos caminhos", () => {
    const out = applyPatch({}, [{ op: "add", path: "/a~1b~0c", value: 1 }]);
    expect(out).toEqual({ "a/b~c": 1 });
  });
});
