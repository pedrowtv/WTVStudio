import type { InputState } from "@wtv/protocol";
import { useTileCanvas } from "../frames";
import { useStore } from "../store";
import { newTxnId } from "../rpc";
import { askText } from "../dialogs";

type Run = (m: string, p?: unknown) => Promise<void>;

function InputCard({ input, index, run }: { input: InputState; index: number; run: Run }) {
  const engine = useStore((s) => s.engine);
  const canvasRef = useTileCanvas(input.id);
  const isProgram = engine?.program.inputId === input.id;
  const isPreview = engine?.preview.inputId === input.id;
  const audio = engine?.audio.inputs[input.id];
  const media = input.media;
  const overlayOn = (slot: number) => engine?.overlays[slot - 1]?.inputId === input.id && engine?.overlays[slot - 1]?.on;

  return (
    <div className={`card${isProgram ? " card-program" : isPreview ? " card-preview" : ""}`}>
      <header className="card-head" onClick={() => run("switcher.setPreview", { inputId: input.id })} onDoubleClick={() => run("switcher.setPreview", { inputId: input.id }).then(() => run("switcher.cut", { txnId: newTxnId() }))}>
        <span className="card-num">{index + 1}</span>
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
        <button className={media?.loop ? "btn btn-card btn-on" : "btn btn-card"} disabled={!media} title="Repetir" onClick={() => media && run("media.setLoop", { inputId: input.id, loop: !media.loop })}>
          Loop
        </button>
        <button className="btn btn-card" disabled={!media} title={media?.state === "playing" ? "Pausa" : "Reproduzir"} onClick={() => media && run(media.state === "playing" ? "media.pause" : "media.play", { inputId: input.id, txnId: newTxnId() })}>
          {media?.state === "playing" ? "❚❚" : "▶"}
        </button>
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
        <button className="btn btn-card" title="Definições da fonte" onClick={async () => { const name = await askText("Nome da fonte", "Nome", input.name); if (name) void run("input.update", { inputId: input.id, name }); }}>
          ⚙
        </button>
      </div>
    </div>
  );
}

export function InputStrip({ run }: { run: Run }) {
  const engine = useStore((s) => s.engine);
  const inputs = engine ? engine.inputOrder.map((id) => engine.inputs[id]).filter(Boolean) : [];
  return (
    <section className="strip">
      {inputs.map((i, idx) => (
        <InputCard key={i.id} input={i} index={idx} run={run} />
      ))}
      {inputs.length === 0 && <div className="muted strip-empty">Sem fontes. Use “Adicionar fonte” na barra inferior.</div>}
    </section>
  );
}
