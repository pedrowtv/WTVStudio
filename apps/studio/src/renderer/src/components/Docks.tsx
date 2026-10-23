import { useEffect, useRef, useState } from "react";
import type { MeterReading } from "@wtv/protocol";
import { AudioPanel, OutputsPanel, PlayoutPanel, SourcesPanel } from "./panels";
import { Overlays } from "./Overlays";

export type DockName = "audio" | "playout" | "saidas" | "fontes" | "overlays";
export const DOCK_TITLES: Record<DockName, string> = { audio: "Audio Mixer", playout: "Playout", saidas: "Saídas", fontes: "Fontes", overlays: "Overlays" };
export const DOCK_ORDER: DockName[] = ["audio", "playout", "saidas", "fontes", "overlays"];
type Run = (method: string, params?: unknown) => Promise<unknown>;

interface DockState { hidden: DockName[]; floating: DockName[]; active: DockName; height: number }
const KEY = "wtv.docks.v1";
function load(): DockState {
  try { const s = JSON.parse(localStorage.getItem(KEY) ?? "null"); if (s && s.active) return { hidden: s.hidden ?? [], active: s.active, height: s.height ?? 300, floating: [] }; } catch { /* sem layout guardado */ }
  return { hidden: [], floating: [], active: "audio", height: 300 };
}

/** Canal entre a janela principal e as janelas flutuantes (mesma origem): "floating" ao abrir, "closed" ao fechar. */
export const dockChannel = typeof BroadcastChannel !== "undefined" ? new BroadcastChannel("wtv-docks") : null;

/** Abre um dock numa janela própria do sistema (Electron) ou do browser. */
export function floatDock(name: DockName): void {
  const title = DOCK_TITLES[name];
  if (window.wtvDesktop?.openPanel) { void window.wtvDesktop.openPanel(name, title); return; }
  window.open(`${location.origin}${location.pathname}?panel=${name}`, `wtv-${name}`, "width=1000,height=640");
}

export function useDocks() {
  const [state, setState] = useState<DockState>(load);
  useEffect(() => { try { localStorage.setItem(KEY, JSON.stringify({ hidden: state.hidden, active: state.active, height: state.height })); } catch { /* sem storage */ } }, [state]);
  useEffect(() => {
    if (!dockChannel) return;
    const onMsg = (ev: MessageEvent) => {
      const m = ev.data as { type: string; name: DockName };
      if (m.type === "floating") setState((s) => ({ ...s, floating: s.floating.includes(m.name) ? s.floating : [...s.floating, m.name] }));
      if (m.type === "closed") setState((s) => ({ ...s, floating: s.floating.filter((d) => d !== m.name), hidden: s.hidden.filter((d) => d !== m.name), active: m.name }));
      if (m.type === "ping") dockChannel.postMessage({ type: "main-alive" });
    };
    dockChannel.addEventListener("message", onMsg);
    return () => dockChannel.removeEventListener("message", onMsg);
  }, []);
  const show = (name: DockName) => setState((s) => ({ ...s, hidden: s.hidden.filter((d) => d !== name), active: name }));
  const hide = (name: DockName) => setState((s) => { const hidden = [...s.hidden, name]; const next = DOCK_ORDER.find((d) => !hidden.includes(d) && !s.floating.includes(d)) ?? s.active; return { ...s, hidden, active: next }; });
  const float = (name: DockName) => { floatDock(name); setState((s) => { const floating = [...s.floating, name]; const next = DOCK_ORDER.find((d) => !s.hidden.includes(d) && !floating.includes(d)) ?? s.active; return { ...s, floating, active: next }; }); };
  const setHeight = (height: number) => setState((s) => ({ ...s, height: Math.max(160, Math.min(700, height)) }));
  return { state, show, hide, float, setHeight, setActive: (active: DockName) => setState((s) => ({ ...s, active })) };
}

export function DockContent({ name, run, meters }: { name: DockName; run: Run; meters: MeterReading[] }) {
  if (name === "audio") return <AudioPanel run={run} meters={meters} />;
  if (name === "playout") return <PlayoutPanel run={run} />;
  if (name === "saidas") return <div className="dock-pad"><OutputsPanel run={run} /></div>;
  if (name === "fontes") return <div className="dock-pad"><SourcesPanel run={run} /></div>;
  return <div className="dock-pad"><Overlays run={run} /></div>;
}

/** Área de docks em separadores, à maneira do OBS: flutuar (⧉), ocultar (✕), altura ajustável pela pega. */
export function DockArea({ docks, run, meters }: { docks: ReturnType<typeof useDocks>; run: Run; meters: MeterReading[] }) {
  const { state } = docks;
  const tabs = DOCK_ORDER.filter((d) => !state.hidden.includes(d) && !state.floating.includes(d));
  const active = tabs.includes(state.active) ? state.active : tabs[0];
  const dragging = useRef<{ y: number; h: number } | null>(null);
  useEffect(() => {
    const move = (e: MouseEvent) => { if (dragging.current) docks.setHeight(dragging.current.h + (dragging.current.y - e.clientY)); };
    const up = () => { dragging.current = null; document.body.style.cursor = ""; };
    window.addEventListener("mousemove", move); window.addEventListener("mouseup", up);
    return () => { window.removeEventListener("mousemove", move); window.removeEventListener("mouseup", up); };
  }, [docks]);
  if (tabs.length === 0) return <div className="dock-area dock-collapsed"><span className="muted small">Todos os painéis estão ocultos ou em janelas próprias. Use o menu Painéis.</span></div>;
  return (
    <div className="dock-area" style={{ height: state.height }}>
      <div className="dock-grip" title="Arrastar para ajustar a altura" onMouseDown={(e) => { dragging.current = { y: e.clientY, h: state.height }; document.body.style.cursor = "ns-resize"; }} />
      <div className="dock-tabs">
        {tabs.map((d) => (
          <button key={d} className={d === active ? "dock-tab on" : "dock-tab"} onClick={() => docks.setActive(d)} onDoubleClick={() => docks.float(d)} title="Duplo clique: flutuar numa janela própria">{DOCK_TITLES[d]}</button>
        ))}
        <span className="spacer" />
        {active && <button className="dock-btn" title="Flutuar numa janela própria (pode ir para outro ecrã)" onClick={() => docks.float(active)}>⧉</button>}
        {active && <button className="dock-btn" title="Ocultar este painel (menu Painéis para voltar a mostrar)" onClick={() => docks.hide(active)}>✕</button>}
      </div>
      <div className="dock-body">{active && <DockContent name={active} run={run} meters={meters} />}</div>
    </div>
  );
}
