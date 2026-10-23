// JSON Patch (RFC 6902), subconjunto add/replace/remove. Aplica de forma imutável
// (devolve um novo objecto) para funcionar bem com o zustand.

import type { PatchOp } from "./types";

function parsePath(path: string): string[] {
  if (path === "") return [];
  if (!path.startsWith("/")) throw new Error(`caminho inválido: ${path}`);
  return path
    .slice(1)
    .split("/")
    .map((p) => p.replace(/~1/g, "/").replace(/~0/g, "~"));
}

function cloneShallow<T>(value: T): T {
  if (Array.isArray(value)) return [...value] as T;
  if (value && typeof value === "object") return { ...(value as object) } as T;
  return value;
}

type Mode = "add" | "replace" | "remove";

function setAt(root: unknown, tokens: string[], value: unknown, mode: Mode): unknown {
  if (tokens.length === 0) return mode === "remove" ? undefined : value;
  const [head, ...rest] = tokens;
  const nextIsIndex = rest.length > 0 && (rest[0] === "-" || /^\d+$/.test(rest[0]));
  const base = root ?? (/^\d+$/.test(head) || head === "-" ? [] : {});
  const copy = cloneShallow(base) as Record<string, unknown> | unknown[];
  if (Array.isArray(copy)) {
    const index = head === "-" ? copy.length : Number(head);
    if (!Number.isInteger(index) || index < 0 || index > copy.length) throw new Error(`índice inválido: ${head}`);
    if (rest.length === 0) {
      if (mode === "remove") copy.splice(index, 1);
      else if (mode === "add") copy.splice(index, 0, value); // RFC 6902: add num array insere
      else copy[index] = value;
    } else {
      copy[index] = setAt(copy[index] ?? (nextIsIndex ? [] : {}), rest, value, mode);
    }
    return copy;
  }
  const obj = copy as Record<string, unknown>;
  if (rest.length === 0) {
    if (mode === "remove") delete obj[head];
    else obj[head] = value;
  } else {
    obj[head] = setAt(obj[head] ?? (nextIsIndex ? [] : {}), rest, value, mode);
  }
  return obj;
}

export function applyPatch<T>(state: T, ops: PatchOp[]): T {
  let current: unknown = state;
  for (const op of ops) {
    const tokens = parsePath(op.path);
    if (op.op === "remove") current = setAt(current, tokens, undefined, "remove");
    else current = setAt(current, tokens, op.value, op.op);
  }
  return current as T;
}
