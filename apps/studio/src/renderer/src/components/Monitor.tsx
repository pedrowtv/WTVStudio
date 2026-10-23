import type { InputState } from "@wtv/protocol";
import { useTileCanvas } from "../frames";
import { useStore } from "../store";
import { newTxnId } from "../rpc";

function fmt(s: number): string {
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = Math.floor(s % 60);
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}`;
}

/** Monitor grande de Preview ou Program com cabeçalho colorido e transporte de media (estilo vMix). */
export function Monitor({ bus, run }: { bus: "preview" | "program"; run: (m: string, p?: unknown) => Promise<unknown> }) {
  const engine = useStore((s) => s.engine);
  const inputId = bus === "preview" ? engine?.preview.inputId : engine?.program.inputId;
  const input: InputState | undefined = inputId ? engine?.inputs[inputId] : undefined;
  const canvasRef = useTileCanvas(bus);
  const media = input?.media;

  return (
    <section className={`monitor monitor-${bus}`}>
      <header className="monitor-head">
        <span className="monitor-title">{input?.name ?? (bus === "preview" ? "Preview" : "Program")}</span>
        <span className="monitor-tag">{bus === "preview" ? "PREVIEW" : "PROGRAM"}</span>
      </header>
      <div className="monitor-video">
        <canvas ref={canvasRef} width={640} height={360} />
        {!input && <div className="monitor-empty">Sem fonte</div>}
      </div>
      <div className="monitor-time">
        {media ? (
          <>
            <span>{fmt(media.positionSeconds)}</span> / <span>{fmt(media.durationSeconds)}</span> /{" "}
            <span className="muted">{fmt(Math.max(0, media.durationSeconds - media.positionSeconds))}</span>
          </>
        ) : (
          <span className="muted">{input ? `${input.kind}${input.format ? ` · ${input.format.width}×${input.format.height}` : ""}` : "—"}</span>
        )}
      </div>
      <div className="monitor-transport">
        <input
          type="range"
          min={0}
          max={media ? Math.max(1, Math.round(media.durationSeconds * 10)) : 1}
          value={media ? Math.round(media.positionSeconds * 10) : 0}
          disabled={!media || !input}
          onChange={(e) => input && run("media.seek", { inputId: input.id, seconds: Number(e.target.value) / 10 })}
        />
        <button className="btn" disabled={!media} onClick={() => input && run("media.seek", { inputId: input.id, seconds: 0 })}>
          Reiniciar
        </button>
        <button
          className="btn btn-icon"
          disabled={!media}
          onClick={() => input && run(media?.state === "playing" ? "media.pause" : "media.play", { inputId: input.id, txnId: newTxnId() })}
          title={media?.state === "playing" ? "Pausa" : "Reproduzir"}
        >
          {media?.state === "playing" ? "❚❚" : "▶"}
        </button>
      </div>
    </section>
  );
}
