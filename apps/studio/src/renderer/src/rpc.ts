// Cliente JSON-RPC 2.0 sobre /ws/control com reconexão (docs/PROTOCOLO.md §2).
import type {
  HelloResult,
  PatchParams,
  RpcError,
  RpcId,
  RpcSuccess,
  SnapshotParams,
  StatsParams,
  LogParams,
} from "@wtv/protocol";

export type ConnectionStatus = "connecting" | "connected" | "disconnected";

export interface RpcClientEvents {
  status: (s: ConnectionStatus) => void;
  hello: (h: HelloResult) => void;
  snapshot: (s: SnapshotParams) => void;
  patch: (p: PatchParams) => void;
  stats: (s: StatsParams) => void;
  log: (l: LogParams) => void;
  restarted: () => void;
}

export class RpcDomainError extends Error {
  constructor(
    public code: string,
    public detail?: string,
  ) {
    super(detail ? `${code}: ${detail}` : code);
  }
}

export class RpcClient {
  private ws: WebSocket | null = null;
  private nextId = 1;
  private pending = new Map<RpcId, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
  private listeners = new Map<keyof RpcClientEvents, Set<(...args: never[]) => void>>();
  private backoffMs = 250;
  private closed = false;
  private lastRev = -1;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private resyncing: Promise<void> | null = null;

  constructor(
    private baseUrl: string, // http://127.0.0.1:7420
    private token: string | null,
    private clientKind: "electron" | "browser",
  ) {}

  on<K extends keyof RpcClientEvents>(event: K, fn: RpcClientEvents[K]): () => void {
    let set = this.listeners.get(event);
    if (!set) {
      set = new Set();
      this.listeners.set(event, set);
    }
    set.add(fn as (...args: never[]) => void);
    return () => set?.delete(fn as (...args: never[]) => void);
  }

  private emit<K extends keyof RpcClientEvents>(event: K, ...args: Parameters<RpcClientEvents[K]>): void {
    for (const fn of this.listeners.get(event) ?? []) (fn as (...a: unknown[]) => void)(...args);
  }

  setLastRev(rev: number): void {
    this.lastRev = rev;
  }

  connect(): void {
    this.closed = false;
    this.open();
  }

  close(): void {
    this.closed = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.ws?.close();
  }

  private wsUrl(): string {
    const u = new URL(this.baseUrl);
    u.protocol = u.protocol === "https:" ? "wss:" : "ws:";
    u.pathname = "/ws/control";
    if (this.token) u.searchParams.set("token", this.token);
    return u.toString();
  }

  private open(): void {
    this.emit("status", "connecting");
    const ws = new WebSocket(this.wsUrl());
    this.ws = ws;
    ws.onopen = async () => {
      this.backoffMs = 250;
      this.emit("status", "connected");
      try {
        const hello = (await this.call("session.hello", {
          clientKind: this.clientKind,
          clientName: this.clientKind === "electron" ? "WTV Studio" : "Browser",
          lastRev: this.lastRev >= 0 ? this.lastRev : undefined,
        })) as HelloResult;
        this.lastRev = hello.snapshot.rev;
        this.emit("hello", hello);
        this.emit("snapshot", hello.snapshot);
      } catch (e) {
        console.error("session.hello falhou", e);
        ws.close();
      }
    };
    ws.onmessage = (ev) => this.handle(String(ev.data));
    ws.onclose = () => {
      this.emit("status", "disconnected");
      for (const p of this.pending.values()) p.reject(new Error("ligação fechada"));
      this.pending.clear();
      if (!this.closed) {
        this.reconnectTimer = setTimeout(() => this.open(), this.backoffMs);
        this.backoffMs = Math.min(5000, this.backoffMs * 2);
      }
    };
    ws.onerror = () => {
      /* onclose trata */
    };
  }

  private handle(text: string): void {
    let msg: Record<string, unknown>;
    try {
      msg = JSON.parse(text);
    } catch {
      return;
    }
    if ("id" in msg && msg.id !== null && msg.id !== undefined && ("result" in msg || "error" in msg)) {
      const p = this.pending.get(msg.id as RpcId);
      if (!p) return;
      this.pending.delete(msg.id as RpcId);
      if ("error" in msg) {
        const err = (msg as unknown as RpcError).error;
        p.reject(new RpcDomainError(err.data?.code ?? String(err.code), err.data?.detail ?? err.message));
      } else {
        p.resolve((msg as unknown as RpcSuccess).result);
      }
      return;
    }
    if ("method" in msg) {
      const params = msg.params as unknown;
      switch (msg.method) {
        case "state.snapshot": {
          const s = params as SnapshotParams;
          this.lastRev = s.rev;
          this.emit("snapshot", s);
          break;
        }
        case "state.patch": {
          const p = params as PatchParams;
          if (this.resyncing) return; // à espera do resync: ignora até chegar o snapshot/patches
          if (p.fromRev !== this.lastRev) {
            void this.resync();
            return;
          }
          this.lastRev = p.toRev;
          this.emit("patch", p);
          break;
        }
        case "stats":
          this.emit("stats", params as StatsParams);
          break;
        case "log":
          this.emit("log", params as LogParams);
          break;
        case "engine.restarted":
          this.emit("restarted");
          break;
      }
    }
  }

  private resync(): Promise<void> {
    if (this.resyncing) return this.resyncing;
    this.resyncing = (async () => {
      try {
        const r = (await this.call("state.resync", { lastRev: this.lastRev })) as
          | { patches: PatchParams[] }
          | { snapshot: SnapshotParams };
        if ("snapshot" in r) {
          this.lastRev = r.snapshot.rev;
          this.emit("snapshot", r.snapshot);
        } else {
          for (const p of r.patches) {
            if (p.fromRev !== this.lastRev) {
              // lacuna dentro do resync: pede snapshot
              const snap = (await this.call("state.resync", { lastRev: -1 })) as { snapshot: SnapshotParams };
              this.lastRev = snap.snapshot.rev;
              this.emit("snapshot", snap.snapshot);
              break;
            }
            this.lastRev = p.toRev;
            this.emit("patch", p);
          }
        }
      } catch (e) {
        console.warn("resync falhou", e);
      } finally {
        this.resyncing = null;
      }
    })();
    return this.resyncing;
  }

  call(method: string, params?: unknown): Promise<unknown> {
    const ws = this.ws;
    if (!ws || ws.readyState !== WebSocket.OPEN) return Promise.reject(new Error("sem ligação ao motor"));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }
}

export function newTxnId(): string {
  return crypto.randomUUID();
}
