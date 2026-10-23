import { useEffect, useState } from "react";
import { INPUT_CATEGORIES, defaultCategory, type InputCategory, type InputState } from "@wtv/protocol";
import { useTileCanvas } from "../frames";
import { useStore } from "../store";
import { newTxnId } from "../rpc";
import { askFields } from "../dialogs";

const catOf = (i: InputState): InputCategory => i.category ?? defaultCategory(i.kind);
const catColour = (c: InputCategory) => INPUT_CATEGORIES.find((x) => x.id === c)?.colour ?? "#666";

type Run = (m: string, p?: unknown) => Promise<unknown>;

function InputCard({ input, index, run }: { input: InputState; index: number; run: Run }) {
  const engine = useStore((s) => s.engine);
  const canvasRef = useTileCanvas(input.id);
  const isProgram = engine?.program.inputId === input.id;
  const isPreview = engine?.preview.inputId === input.id;
  const audio = engine?.audio.inputs[input.id];
  const media = input.media;
  // A fonte Replay é comandada pelo painel Replay (replay.*): Loop e ▶/❚❚ genéricos (media.*) desalinhariam o estado do lance.
  const isReplay = input.kind === "replay";
  const overlayOn = (slot: number) => engine?.overlays[slot - 1]?.inputId === input.id && engine?.overlays[slot - 1]?.on;

  return (
    <div className={`card${isProgram ? " card-program" : isPreview ? " card-preview" : ""}`}>
      <header className="card-head" onClick={() => run("switcher.setPreview", { inputId: input.id })} onDoubleClick={() => run("switcher.setPreview", { inputId: input.id }).then(() => run("switcher.cut", { txnId: newTxnId() }))}>
        <span className="card-num">{index + 1}</span>
        <span className="card-cat" style={{ background: catColour(catOf(input)) }} title={INPUT_CATEGORIES.find((c) => c.id === catOf(input))?.label} />
        <span className="card-name" title={input.statusCode ?? input.status}>
          {input.name}
        </span>
        {input.status !== "live" && <span className="card-status">{input.status === "noSignal" ? "SEM SINAL" : input.status === "error" ? "ERRO" : input.status}</span>}
      </header>
      <div className="card-video" onClick={() => run("switcher.setPreview", { inputId: input.id })} onDoubleClick={() => run("switcher.setPreview", { inputId: input.id }).then(() => run("switcher.cut", { txnId: newTxnId() }))}>
        <canvas ref={canvasRef} width={320} height={180} />
      </div>
      <div className="card-row">
        <button className="btn btn-card" title="Remover" onClick={() => { if (window.confirm(`Fechar "${input.name}"?`)) void run("input.remove", { inputId: input.id }); }}>
          Fechar
        </button>
        <button className="btn btn-card" title="Preview + fade" onClick={() => run("switcher.setPreview", { inputId: input.id }).then(() => run("switcher.transition", { kind: "fade", durationFrames: 25, txnId: newTxnId() }))}>
          Quick Play
        </button>
        <button className="btn btn-card" title="Preview + cut" onClick={() => run("switcher.setPreview", { inputId: input.id }).then(() => run("switcher.cut", { txnId: newTxnId() }))}>
          Cut
        </button>
        {!isReplay && (
          <>
            <button className={media?.loop ? "btn btn-card btn-on" : "btn btn-card"} disabled={!media} title="Repetir" onClick={() => media && run("media.setLoop", { inputId: input.id, loop: !media.loop })}>
              Loop
            </button>
            <button className="btn btn-card" disabled={!media} title={media?.state === "playing" ? "Pausa" : "Reproduzir"} onClick={() => media && run(media.state === "playing" ? "media.pause" : "media.play", { inputId: input.id, txnId: newTxnId() })}>
              {media?.state === "playing" ? "❚❚" : "▶"}
            </button>
          </>
        )}
      </div>
      <div className="card-row">
        {[1, 2, 3, 4].map((slot) => (
          <button
            key={slot}
            className={overlayOn(slot) ? "btn btn-card btn-program" : "btn btn-card"}
            title={`Overlay ${slot}`}
            onClick={() => run("overlay.set", { slot, inputId: input.id, on: !overlayOn(slot) })}
          >
            {slot}
          </button>
        ))}
        <button
          className={input.hasAudio && !audio?.mute ? "btn btn-card btn-audio-on" : "btn btn-card"}
          disabled={!input.hasAudio}
          title={input.hasAudio ? (audio?.mute ? "Áudio desligado" : "Áudio ligado") : "Sem áudio"}
          onClick={() => run("audio.setMute", { inputId: input.id, on: !audio?.mute })}
        >
          Áudio
        </button>
        <button className="btn btn-card" title="Definições da fonte (nome e categoria)" onClick={async () => { const f = await askFields("Definições da fonte", [{ key: "name", label: "Nome", defaultValue: input.name }, { key: "category", label: `Categoria (${INPUT_CATEGORIES.map((c) => c.id).join(" | ")})`, defaultValue: catOf(input) }]); if (!f) return; const category = INPUT_CATEGORIES.some((c) => c.id === f.category) ? f.category : null; void run("input.update", { inputId: input.id, name: f.name || input.name, category }); }}>
          ⚙
        </button>
      </div>
    </div>
  );
}

const TAB_KEY = "wtv.strip.tab";

/** Separadores de categorias na faixa de fontes (todas, câmaras, VT, gráficos, chamadas, áudio), à maneira do FreeMix/vMix. */
export function InputTabs({ tab, setTab }: { tab: string; setTab: (t: string) => void }) {
  const engine = useStore((s) => s.engine);
  const inputs = engine ? engine.inputOrder.map((id) => engine.inputs[id]).filter(Boolean) : [];
  const count = (c: InputCategory) => inputs.filter((i) => catOf(i) === c).length;
  return (
    <span className="strip-tabs">
      <button className={tab === "all" ? "strip-tab on" : "strip-tab"} onClick={() => setTab("all")}>Todas <b>{inputs.length}</b></button>
      {INPUT_CATEGORIES.map((c) => (
        <button key={c.id} className={tab === c.id ? "strip-tab on" : "strip-tab"} style={{ "--cat": c.colour } as React.CSSProperties} onClick={() => setTab(c.id)}><i />{c.label} <b>{count(c.id)}</b></button>
      ))}
    </span>
  );
}

export function useStripTab(): [string, (t: string) => void] {
  const [tab, setTab] = useState<string>(() => { try { return localStorage.getItem(TAB_KEY) ?? "all"; } catch { return "all"; } });
  useEffect(() => { try { localStorage.setItem(TAB_KEY, tab); } catch { /* sem storage */ } }, [tab]);
  return [tab, setTab];
}

export function InputStrip({ run, tab }: { run: Run; tab: string }) {
  const engine = useStore((s) => s.engine);
  const inputs = engine ? engine.inputOrder.map((id) => engine.inputs[id]).filter(Boolean) : [];
  const shown = tab === "all" ? inputs : inputs.filter((i) => catOf(i) === tab);
  return (
    <section className="strip">
      {shown.map((i) => (
        <InputCard key={i.id} input={i} index={inputs.indexOf(i)} run={run} />
      ))}
      {inputs.length === 0 && <div className="muted strip-empty">Sem fontes. Use “Adicionar fonte” na barra inferior.</div>}
      {inputs.length > 0 && shown.length === 0 && <div className="muted strip-empty">Sem fontes nesta categoria. Mude a categoria de uma fonte no ⚙ do cartão.</div>}
    </section>
  );
}
