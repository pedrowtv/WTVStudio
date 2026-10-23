import type { Rect } from "@wtv/protocol";
import { useStore } from "../store";

const PRESETS: { id: string; label: string; rect: Rect }[] = [
  { id: "full", label: "Ecrã inteiro", rect: { x: 0, y: 0, w: 1, h: 1 } },
  { id: "tr", label: "PiP sup. dir.", rect: { x: 0.65, y: 0.05, w: 0.3, h: 0.3 } },
  { id: "tl", label: "PiP sup. esq.", rect: { x: 0.05, y: 0.05, w: 0.3, h: 0.3 } },
  { id: "br", label: "PiP inf. dir.", rect: { x: 0.65, y: 0.65, w: 0.3, h: 0.3 } },
  { id: "bl", label: "PiP inf. esq.", rect: { x: 0.05, y: 0.65, w: 0.3, h: 0.3 } },
  { id: "half", label: "Metade dir.", rect: { x: 0.5, y: 0, w: 0.5, h: 1 } },
];

/** Os 4 slots de overlay (D10): fonte, ligar/desligar, posição e opacidade. */
export function Overlays({ run }: { run: (method: string, params?: unknown) => Promise<unknown> }) {
  const engine = useStore((s) => s.engine);
  if (!engine) return null;
  const inputs = engine.inputOrder.map((id) => engine.inputs[id]).filter(Boolean);

  return (
    <section className="overlays">
      <h3>Overlays</h3>
      <div className="overlay-grid">
        {engine.overlays.map((o, i) => {
          const slot = i + 1;
          const preset = PRESETS.find((p) => Math.abs(p.rect.x - o.rect.x) < 0.001 && Math.abs(p.rect.w - o.rect.w) < 0.001 && Math.abs(p.rect.y - o.rect.y) < 0.001)?.id ?? "custom";
          return (
            <div key={slot} className={o.on ? "overlay overlay-on" : "overlay"}>
              <button
                className={o.on ? "btn btn-program" : "btn"}
                disabled={!o.inputId}
                onClick={() => run("overlay.set", { slot, on: !o.on })}
                title={o.inputId ? "Ligar/desligar" : "Escolha uma fonte"}
              >
                {slot}
              </button>
              <select value={o.inputId ?? ""} onChange={(e) => run("overlay.set", { slot, inputId: e.target.value || null, on: o.on && !!e.target.value })}>
                <option value="">— fonte —</option>
                {inputs.map((inp) => (
                  <option key={inp.id} value={inp.id}>
                    {inp.name}
                  </option>
                ))}
              </select>
              <select value={preset} onChange={(e) => { const p = PRESETS.find((x) => x.id === e.target.value); if (p) void run("overlay.set", { slot, rect: p.rect }); }}>
                {preset === "custom" && <option value="custom">personalizado</option>}
                {PRESETS.map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.label}
                  </option>
                ))}
              </select>
              <input type="range" min={0} max={100} value={Math.round(o.opacity * 100)} title="Opacidade" onChange={(e) => run("overlay.set", { slot, opacity: Number(e.target.value) / 100 })} />
            </div>
          );
        })}
      </div>
    </section>
  );
}
