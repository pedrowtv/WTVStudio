import { useEffect, useRef, useState } from "react";
import type { TransitionKind, WipeDirection } from "@wtv/protocol";
import { useStore } from "../store";
import { newTxnId } from "../rpc";

const WIPES: { id: WipeDirection; label: string }[] = [
  { id: "left", label: "Esquerda → direita" },
  { id: "right", label: "Direita → esquerda" },
  { id: "up", label: "Cima → baixo" },
  { id: "down", label: "Baixo → cima" },
  { id: "box", label: "Caixa" },
  { id: "circle", label: "Círculo" },
  { id: "diagonalUp", label: "Diagonal ↗" },
  { id: "diagonalDown", label: "Diagonal ↘" },
];

/** Coluna central: Quick Play, Cut, transições, FTB, overlays 1–4 e T-bar (estilo vMix). */
export function TransitionColumn({ run }: { run: (m: string, p?: unknown) => Promise<void> }) {
  const engine = useStore((s) => s.engine);
  const [wipe, setWipe] = useState<WipeDirection>("left");
  const [frames, setFrames] = useState(25);
  const [tbar, setTbar] = useState(0);
  const dragging = useRef(false);
  const pending = useRef<number | null>(null);
  const raf = useRef<number | null>(null);
  const transition = engine?.program.transition;

  useEffect(() => {
    if (!dragging.current) setTbar(transition ? transition.progress : 0);
  }, [transition?.progress, transition]);

  // Largar o rato fora do slider também termina o arrasto; cancela o RAF ao desmontar.
  useEffect(() => {
    const up = () => {
      if (!dragging.current) return;
      dragging.current = false;
      setTbar((v) => {
        if (v >= 0.98) {
          sendTbar(1);
          return 0;
        }
        return v;
      });
    };
    window.addEventListener("pointerup", up);
    return () => {
      window.removeEventListener("pointerup", up);
      if (raf.current !== null) cancelAnimationFrame(raf.current);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const sendTbar = (v: number) => {
    pending.current = v;
    if (raf.current !== null) return;
    raf.current = requestAnimationFrame(() => {
      raf.current = null;
      const p = pending.current;
      pending.current = null;
      if (p !== null) void run("switcher.tbar", { position: p });
    });
  };

  const auto = (kind: TransitionKind) =>
    run("switcher.transition", {
      kind,
      durationFrames: frames,
      wipe: kind === "wipe" ? { direction: wipe, softness: 0.05 } : undefined,
      colour: kind === "dip" ? "#000000" : undefined,
      txnId: newTxnId(),
    });
  const cut = () => run("switcher.cut", { txnId: newTxnId() });

  // Atalhos: 1–9 preview, Enter cut, Espaço fade, F FTB
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement | null;
      if (t && (t.tagName === "INPUT" || t.tagName === "SELECT" || t.tagName === "TEXTAREA" || t.tagName === "BUTTON" || t.isContentEditable)) return;
      if (e.metaKey || e.ctrlKey || e.altKey || e.repeat) return;
      if (document.querySelector(".modal-backdrop")) return; // atalhos nunca disparam com um modal aberto
      if (e.key >= "1" && e.key <= "9") {
        const id = engine?.inputOrder[Number(e.key) - 1];
        if (id) void run("switcher.setPreview", { inputId: id });
      } else if (e.key === "Enter") void cut();
      else if (e.key === " ") {
        e.preventDefault();
        void auto("fade");
      } else if (e.key.toLowerCase() === "f") void run("switcher.ftb", { on: !engine?.program.ftb });
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  const overlayFor = (slot: number) => engine?.overlays[slot - 1];
  const toggleOverlay = (slot: number) => {
    const o = overlayFor(slot);
    if (!o) return;
    // Sem fonte atribuída: usa o Preview actual (comportamento rápido tipo vMix)
    if (!o.inputId) {
      const id = engine?.preview.inputId;
      if (!id) return;
      void run("overlay.set", { slot, inputId: id, on: true });
    } else void run("overlay.set", { slot, on: !o.on });
  };

  return (
    <aside className="transitions">
      <button className="btn btn-col" onClick={() => void auto("fade")} title="Espaço">
        Quick Play
      </button>
      <button className="btn btn-col" onClick={() => void cut()} title="Enter">
        Cut
      </button>
      <button className="btn btn-col" onClick={() => void auto("fade")}>
        Fade
      </button>
      <div className="btn-split">
        <button className="btn btn-col" onClick={() => void auto("wipe")}>
          Wipe
        </button>
        <select value={wipe} onChange={(e) => setWipe(e.target.value as WipeDirection)} title="Direcção do wipe">
          {WIPES.map((w) => (
            <option key={w.id} value={w.id}>
              {w.label}
            </option>
          ))}
        </select>
      </div>
      <button className="btn btn-col" onClick={() => void auto("dip")}>
        Dip
      </button>
      <label className="trans-dur">
        <input type="number" min={1} max={300} value={frames} onChange={(e) => setFrames(Math.max(1, Number(e.target.value) || 1))} />
        <span className="muted small">frames</span>
      </label>
      <button className={engine?.program.ftb ? "btn btn-col btn-program" : "btn btn-col"} onClick={() => run("switcher.ftb", { on: !engine?.program.ftb })} title="F">
        FTB
      </button>
      <div className="overlay-row">
        {[1, 2, 3, 4].map((slot) => {
          const o = overlayFor(slot);
          return (
            <button key={slot} className={o?.on ? "btn btn-ov btn-program" : "btn btn-ov"} onClick={() => toggleOverlay(slot)} title={o?.inputId ? (engine?.inputs[o.inputId]?.name ?? "") : "Usa o Preview"}>
              {slot}
            </button>
          );
        })}
      </div>
      <div className="tbar-wrap">
        <input
          className="tbar-v"
          type="range"
          min={0}
          max={1000}
          value={Math.round(tbar * 1000)}
          onPointerDown={() => (dragging.current = true)}
          onChange={(e) => {
            const v = Number(e.target.value) / 1000;
            setTbar(v);
            sendTbar(v);
          }}
        />
      </div>
    </aside>
  );
}
