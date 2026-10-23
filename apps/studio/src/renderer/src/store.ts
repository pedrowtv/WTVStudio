// Estado da UI: o estado do motor (aplicado por patches) + ligação + telemetria.
import { create } from "zustand";
import { applyPatch, type EngineState, type LogParams, type PatchParams, type StatsParams } from "@wtv/protocol";
import type { ConnectionStatus, RpcClient } from "./rpc";

export interface UiStore {
  connection: ConnectionStatus;
  engine: EngineState | null;
  engineVersion: string | null;
  stats: StatsParams | null;
  log: LogParams[];
  client: RpcClient | null;
  setClient: (c: RpcClient) => void;
  setConnection: (s: ConnectionStatus) => void;
  setSnapshot: (s: EngineState) => void;
  applyPatch: (p: PatchParams) => void;
  setStats: (s: StatsParams) => void;
  pushLog: (l: LogParams) => void;
}

export const useStore = create<UiStore>((set) => ({
  connection: "disconnected",
  engine: null,
  engineVersion: null,
  stats: null,
  log: [],
  client: null,
  setClient: (client) => set({ client }),
  setConnection: (connection) => set({ connection }),
  setSnapshot: (engine) => set({ engine, engineVersion: engine.system.engineVersion }),
  applyPatch: (p) => set((s) => (s.engine ? { engine: applyPatch(s.engine, p.ops) } : {})),
  setStats: (stats) => set({ stats }),
  pushLog: (l) => set((s) => ({ log: [...s.log.slice(-199), l] })),
}));

/** Liga o cliente RPC ao store. Chamado uma vez no arranque. */
export function bindClient(client: RpcClient): void {
  const s = useStore.getState();
  s.setClient(client);
  client.on("status", s.setConnection);
  client.on("snapshot", (snap) => useStore.getState().setSnapshot(snap.state));
  client.on("patch", (p) => useStore.getState().applyPatch(p));
  client.on("stats", (st) => useStore.getState().setStats(st));
  client.on("log", (l) => useStore.getState().pushLog(l));
  client.on("restarted", () =>
    useStore.getState().pushLog({ level: "warning", code: "ENGINE_RESTARTED", message: "O motor reiniciou", at: new Date().toISOString() }),
  );
}
