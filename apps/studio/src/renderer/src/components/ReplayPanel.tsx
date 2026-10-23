import { useEffect, useRef, useState } from "react";
import type { InputState, ReplayState } from "@wtv/protocol";
import { useStore } from "../store";

type Run = (method: string, params?: unknown) => Promise<unknown>;

/** Durações de buffer oferecidas (segundos por ângulo). */
const BUFFERS = [4, 6, 8, 10, 15, 20, 30];
const SPEEDS = [25, 50, 100];
const STATUS_LABEL: Record<ReplayState["status"], string> = { idle: "parado", buffering: "● buffer a gravar", loaded: "lance carregado", unavailable: "indisponível" };
const STATUS_CLASS: Record<ReplayState["status"], string> = { idle: "tally", buffering: "tally rec", loaded: "tally on", unavailable: "tally warn" };

/** Estado "sem suporte": motor sem o campo replay (comandos replay.* ausentes) ou plugin Replay Source não carregado. */
const UNAVAILABLE: ReplayState = { bufferSeconds: 8, angles: [], inputId: null, loadedAngle: null, speedPercent: 100, paused: false, onAir: false, liveInput: null, memoryMB: 0, status: "unavailable" };

/** Fontes que podem ser ângulos: têm vídeo e não são o próprio Replay. */
const isAngleCandidate = (i: InputState | undefined): i is InputState => !!i && i.kind !== "title" && i.kind !== "audioDevice" && i.kind !== "replay";

/**
 * Painel de replay instantâneo (à maneira do vMix/FreeMix): ângulos armados com buffer em RAM, capturar lance por ângulo,
 * transporte com câmara lenta e botão NO AR que leva a fonte Replay a Program (e volta ao vivo).
 */
export function ReplayPanel({ run }: { run: Run }) {
  const engine = useStore((s) => s.engine);
  const replay = engine?.replay ?? UNAVAILABLE;
  const unavailable = replay.status === "unavailable";
  // Campo numérico da velocidade: edita-se localmente e envia-se ao confirmar (Enter / sair do campo).
  const [speedField, setSpeedField] = useState(String(replay.speedPercent));
  useEffect(() => { setSpeedField(String(replay.speedPercent)); }, [replay.speedPercent]);
  // Última lista de ângulos enviada ao motor: cliques rápidos nas checkboxes derivam do pedido em curso e não do estado já
  // desactualizado do render anterior (que desarmaria o primeiro). Só se limpa quando não há pedidos em curso (inflight) e o
  // estado real já coincide, ou quando o último pedido falhou: assim o patch de um pedido antigo, a chegar a meio de um mais
  // recente, não apaga a lista nem desarma o ângulo do clique seguinte.
  const pendingRef = useRef<string[] | null>(null);
  const inflight = useRef(0);
  useEffect(() => { if (inflight.current === 0) pendingRef.current = null; }, [replay.angles]);
  if (!engine) return null;

  const inputs = engine.inputOrder.map((id) => engine.inputs[id]).filter(isAngleCandidate);
  const numberOf = (id: string) => engine.inputOrder.indexOf(id) + 1;
  const nameOf = (id: string | null) => (id ? engine.inputs[id]?.name ?? "—" : "—");
  const angles = replay.angles.filter((id) => !!engine.inputs[id]);
  const raster = engine.project.raster;
  // Estimativa por ângulo: a do motor (formato real de cada fonte + lances guardados) quando há ângulos; sem ângulos, o pior
  // caso ao raster (BGRA sem compressão: largura × altura × 4 bytes × fps × segundos).
  const rasterMB = Math.round((raster.width * raster.height * 4 * raster.fps * replay.bufferSeconds) / 1e6);
  const perAngleMB = replay.angles.length ? Math.round(replay.memoryMB / replay.angles.length) : rasterMB;
  const totalGB = Math.round((replay.angles.length ? replay.memoryMB : rasterMB) / 100) / 10;
  const memClass = replay.memoryMB > 2500 ? "replay-mem over" : replay.memoryMB > 1500 ? "replay-mem warn" : "replay-mem";

  const setAngles = async (next: string[]) => {
    pendingRef.current = next;
    inflight.current++;
    let r: unknown;
    try {
      r = await run("replay.setup", { angles: next });
    } finally {
      // Quando o último pedido termina: run devolve undefined se o motor recusou (volta-se a derivar do estado real); no
      // sucesso só se larga a lista pendente se o motor já a reflecte (o patch chega antes da resposta, mas não se assume).
      if (--inflight.current === 0) {
        const real = useStore.getState().engine?.replay?.angles ?? [];
        const pending = pendingRef.current;
        const same = !!pending && real.length === pending.length && real.every((a, i) => a === pending[i]);
        if (r === undefined || same) pendingRef.current = null;
      }
    }
  };
  const toggleAngle = (id: string, on: boolean) => {
    const base = pendingRef.current ?? angles;
    return setAngles(on ? (base.includes(id) ? base : [...base, id]) : base.filter((a) => a !== id));
  };
  const setSpeed = (percent: number) => { if (percent >= 1 && percent <= 400) void run("replay.setSpeed", { percent: Math.round(percent) }); };
  const commitSpeed = () => { const v = Number(speedField); if (Number.isFinite(v) && v >= 1 && v <= 400) setSpeed(v); else setSpeedField(String(replay.speedPercent)); };
  const toggleAir = () => run(replay.onAir ? "replay.backToLive" : "replay.onAir", {});
  const canPlay = !unavailable && angles.length > 0;
  const hasClip = replay.status === "loaded";
  // "A tocar" vem do estado de media da própria fonte Replay (é o que o motor reproduz); sem media, do campo paused.
  const replayMedia = replay.inputId ? engine.inputs[replay.inputId]?.media : undefined;
  const playing = replayMedia ? replayMedia.state === "playing" : !replay.paused;

  return (
    <div className="replay">
      <div className="replay-head">
        <span className={STATUS_CLASS[replay.status] ?? "tally"}>{STATUS_LABEL[replay.status] ?? replay.status}</span>
        {unavailable && <span className="muted">plugin Replay Source não carregado</span>}
        <span className={memClass} title="RAM estimada dos buffers: segundos × ângulos × raster (sem compressão)">RAM {replay.memoryMB.toFixed(0)} MB{replay.memoryMB > 1500 ? " ⚠" : ""}</span>
        <label>
          Buffer
          <select value={BUFFERS.includes(replay.bufferSeconds) ? replay.bufferSeconds : ""} disabled={unavailable} onChange={(e) => { const s = Number(e.target.value); if (s > 0) void run("replay.setup", { bufferSeconds: s }); }}>
            {!BUFFERS.includes(replay.bufferSeconds) && <option value="">{replay.bufferSeconds} s</option>}
            {BUFFERS.map((s) => <option key={s} value={s}>{s} s</option>)}
          </select>
          por ângulo
        </label>
        <span className="muted">{angles.length} ângulo(s) · ≈ {perAngleMB} MB cada{angles.length ? "" : " (pior caso ao raster)"}</span>
        <span className="spacer" />
        {replay.inputId && <span className="muted">fonte Replay nº {numberOf(replay.inputId)}</span>}
      </div>

      {replay.onAir && <div className="replay-onair-bar">● Replay em Program — "Voltar ao vivo" ou R repõe {nameOf(replay.liveInput)}</div>}
      {unavailable && !engine.replay && <div className="replay-unavailable">O motor não anuncia suporte de replay (comandos replay.* ausentes). Actualize o motor ou verifique o plugin Replay Source.</div>}

      <div className="replay-grid">
        <section>
          <h3>Ângulos</h3>
          <div className="replay-angles">
            {inputs.map((i) => {
              const armed = angles.includes(i.id);
              return (
                <label key={i.id} className={`replay-angle${armed ? " armed" : ""}${replay.loadedAngle === i.id ? " loaded" : ""}`} title={armed ? "Desarmar (liberta o buffer)" : "Armar: grava os últimos segundos desta fonte em RAM"}>
                  <input type="checkbox" checked={armed} disabled={unavailable} onChange={(e) => void toggleAngle(i.id, e.target.checked)} />
                  <b className="card-num">{numberOf(i.id)}</b>
                  <span>{i.name}</span>
                </label>
              );
            })}
            {inputs.length === 0 && <span className="muted small">Sem fontes com vídeo para armar.</span>}
          </div>
          <div className="replay-capture">
            {angles.map((id, n) => (
              <button key={id} className={replay.loadedAngle === id ? "btn replay-capture-btn btn-sel" : "btn replay-capture-btn"} disabled={unavailable} title={`Carregar os últimos ${replay.bufferSeconds} s de "${nameOf(id)}" na fonte Replay (tecla ⇧${n + 1})`} onClick={() => void run("replay.capture", { inputId: id })}>
                <kbd>⇧{n + 1}</kbd>
                <span>Capturar lance {n + 1}</span>
                <small>{numberOf(id)} · {nameOf(id)}</small>
              </button>
            ))}
            {angles.length === 0 && <span className="muted small">Arme pelo menos um ângulo para poder capturar lances.</span>}
          </div>
        </section>

        <section>
          <h3>Transporte</h3>
          <div className="replay-loaded">lance: {replay.loadedAngle ? `${numberOf(replay.loadedAngle)} · ${nameOf(replay.loadedAngle)}` : "nenhum"}{hasClip ? ` · ${replay.speedPercent} %${playing ? "" : " · em pausa"}` : ""}</div>
          <div className="replay-transport">
            <button className="btn" disabled={!canPlay} title={playing ? "Pausa" : "Retomar"} onClick={() => void run("replay.pause", { on: playing })}>{playing ? "⏸" : "▶"}</button>
            <button className="btn" disabled={!canPlay} title="Voltar ao início do lance" onClick={() => void run("replay.restart", {})}>⟲ Reiniciar</button>
            <button className="btn" disabled={!canPlay} title="Lance anterior (guardados)" onClick={() => void run("replay.previous", {})}>◀ Anterior</button>
            <button className="btn" disabled={!canPlay} title="Lance seguinte (guardados)" onClick={() => void run("replay.next", {})}>Seguinte ▶</button>
          </div>
          <div className="replay-speed">
            {SPEEDS.map((p) => <button key={p} className={replay.speedPercent === p ? "btn btn-sel" : "btn"} disabled={!canPlay} title={p === 50 ? "Câmara lenta (tecla [)" : p === 100 ? "Velocidade normal (tecla ])" : "Câmara muito lenta"} onClick={() => setSpeed(p)}>{p} %</button>)}
            <input type="number" min={1} max={400} step={5} value={speedField} disabled={!canPlay} title="Velocidade em % (1 a 400)" onChange={(e) => setSpeedField(e.target.value)} onBlur={commitSpeed} onKeyDown={(e) => { if (e.key === "Enter") { commitSpeed(); (e.target as HTMLInputElement).blur(); } }} />
            <span className="muted small">%</span>
            <span className="spacer" />
            <button className="btn btn-x" disabled={!canPlay} title="Esvazia os lances guardados e volta a gravar o buffer" onClick={() => { if (window.confirm("Limpar os lances guardados e o buffer do replay?")) void run("replay.clear", {}); }}>Limpar</button>
          </div>
          <p className="hint">Buffers sem compressão: ≈ 0,4 GB por segundo e por ângulo a 1080p50. Com {angles.length || 1} ângulo(s) e {replay.bufferSeconds} s gasta ≈ {totalGB} GB (inclui os 2 lances guardados); o motor recusa acima de 2,5 GB.</p>
        </section>

        <section className="replay-air">
          <h3>No ar</h3>
          <button className={replay.onAir ? "btn btn-program replay-air-btn on" : "btn replay-air-btn"} disabled={unavailable || !replay.inputId} title={replay.onAir ? "Voltar ao vivo (tecla R)" : "Cut da fonte Replay para Program (tecla R)"} onClick={() => void toggleAir()}>{replay.onAir ? "● No ar" : "No ar"}</button>
          <button className="btn replay-live-btn" disabled={!replay.onAir} title="Cut de volta ao input que estava em Program" onClick={() => void run("replay.backToLive", {})}>Voltar ao vivo{replay.liveInput ? ` · ${nameOf(replay.liveInput)}` : ""}</button>
          <span className="muted small">{replay.inputId ? `A fonte Replay (nº ${numberOf(replay.inputId)}) também vai a Preview/Program como outra qualquer.` : "A fonte Replay aparece na faixa quando houver ângulos armados."}</span>
        </section>
      </div>
    </div>
  );
}
