import { useRef, useState } from "react";
import type { MeterReading, PlaylistConfig } from "@wtv/protocol";
import { useStore } from "../store";
import { newTxnId } from "../rpc";
import { askFields, askText, pickFiles, pickFolder } from "../dialogs";

type Run = (method: string, params?: unknown) => Promise<unknown>;

interface PluginProperty { name: string; description: string; type: "float" | "int" | "bool" | "text" | "list"; min?: number; max?: number; step?: number; options?: { name: string; value: string | number }[] }

/** Parâmetros de um filtro de áudio da libobs numa caixa de campos (sem janela própria do plugin). */
async function editPluginParams(run: Run, inputId: string, pluginId: string, title: string): Promise<void> {
  const r = (await run("audio.getPluginParams", { inputId, pluginId })) as { properties: PluginProperty[]; values: Record<string, unknown> } | undefined;
  if (!r) return;
  const fields = r.properties.map((p) => {
    const cur = r.values[p.name];
    let label = p.description;
    if (p.type === "float" || p.type === "int") label += ` (${p.min} a ${p.max})`;
    if (p.type === "bool") label += " (sim/não)";
    if (p.type === "list" && p.options) label += ` (${p.options.map((o) => `${o.name}=${o.value}`).join(", ")})`;
    return { key: p.name, label, defaultValue: cur === undefined ? "" : String(cur) };
  });
  const out = await askFields(`Parâmetros: ${title}`, fields);
  if (!out) return;
  const params: Record<string, unknown> = {};
  for (const p of r.properties) {
    const v = out[p.name];
    if (v === undefined || v === "") continue;
    if (p.type === "float") params[p.name] = Number(v);
    else if (p.type === "int") params[p.name] = Math.round(Number(v));
    else if (p.type === "bool") params[p.name] = /^(sim|s|true|1|yes)$/i.test(v);
    else if (p.type === "list" && typeof p.options?.[0]?.value === "number") params[p.name] = Number(v);
    else params[p.name] = v;
  }
  await run("audio.setPluginParam", { inputId, pluginId, params });
}

// ---------------------------------------------------------------- Fontes

export function SourcesPanel({ run }: { run: Run }) {
  const engine = useStore((s) => s.engine);
  const inputs = engine ? engine.inputOrder.map((id) => engine.inputs[id]).filter(Boolean) : [];
  const add = (kind: string, config: unknown, name?: string) => run("input.add", { kind, name, config });

  return (
    <>
      <h3>Adicionar fonte</h3>
      <div className="buttons">
        <button className="btn" onClick={() => add("synthetic", { pattern: "bars", tone: true }, "Barras")}>Barras + tom</button>
        <button className="btn" onClick={() => add("synthetic", { pattern: "colour", colour: "#2060c0" }, "Cor")}>Cor</button>
        <button className="btn" onClick={() => add("synthetic", { pattern: "testPattern" }, "Padrão")}>Padrão</button>
        <button className="btn" onClick={() => add("synthetic", { pattern: "sync" }, "Sincronismo")}>Sincronismo</button>
        <button className="btn" onClick={async () => { for (const path of await pickFiles("video")) void add("media", { path, speed: 1 }); }}>Ficheiro…</button>
        <button className="btn" onClick={async () => { for (const path of await pickFiles("image")) void add("image", { path }); }}>Imagem…</button>
        <button className="btn" onClick={async () => { const f = await askFields("Novo oráculo", [{ key: "name", label: "Nome", defaultValue: "" }, { key: "role", label: "Função / cargo", defaultValue: "WayTV" }]); if (f?.name) void add("title", { template: "lowerThird", fields: { name: f.name, role: f.role ?? "" } }, "Oráculo"); }}>Oráculo…</button>
        <button className="btn" onClick={async () => { const f = await askFields("Novo título", [{ key: "title", label: "Título", defaultValue: "" }, { key: "subtitle", label: "Subtítulo", defaultValue: "" }]); if (f?.title) void add("title", { template: "fullscreen", fields: { title: f.title, subtitle: f.subtitle ?? "" } }, "Título"); }}>Título…</button>
        <button className="btn" onClick={() => add("screen", { audio: false, showCursor: true }, "Ecrã")}>Ecrã</button>
        <button className="btn" onClick={async () => { const f = await askFields("Entrada SRT", [{ key: "url", label: "URL (srt://:9000 para receber, srt://host:porta para ligar)", defaultValue: "srt://:9000" }, { key: "latency", label: "Latência (ms)", defaultValue: "120" }, { key: "passphrase", label: "Passphrase (opcional)", defaultValue: "" }]); if (f?.url) void add("srt", { url: f.url, latencyMs: Number(f.latency) || 120, passphrase: f.passphrase || undefined }, "SRT"); }}>SRT…</button>
        {engine?.devices.ndiSources.map((n) => (
          <button key={n.name} className="btn" title={n.url} onClick={() => add("ndi", { sourceName: n.name, bandwidth: "highest" }, n.name.replace(/^.*\((.*)\)$/, "$1"))}>📡 {n.name}</button>
        ))}
        {engine?.devices.video.map((d) => (
          <button key={d.uniqueId} className="btn" onClick={() => add("camera", { uniqueId: d.uniqueId, audio: true }, d.name)}>📷 {d.name}</button>
        ))}
        <button className="btn btn-x" title="Procurar câmaras e ecrãs" onClick={() => run("devices.refresh")}>⟳</button>
      </div>

      <h3>Fontes ({inputs.length})</h3>
      <ul className="lista">
        {inputs.map((i, idx) => (
          <li key={i.id}>
            <span className={`dot dot-${i.status}`} title={i.statusCode ?? i.status} />
            <span className="nome">
              <span className="muted small">{idx + 1}</span> {i.name}
            </span>
            <span className="muted small">
              {i.kind}
              {i.format ? ` ${i.format.width}×${i.format.height}` : ""}
              {i.status === "error" && i.statusCode ? ` · ${i.statusCode}` : ""}
            </span>
            {i.media && (
              <span className="transporte">
                <button className="btn btn-x" onClick={() => run(i.media!.state === "playing" ? "media.pause" : "media.play", { inputId: i.id, txnId: newTxnId() })}>{i.media.state === "playing" ? "❚❚" : "▶"}</button>
                <button className="btn btn-x" onClick={() => run("media.stop", { inputId: i.id, txnId: newTxnId() })}>■</button>
                <button className={i.media.loop ? "btn btn-x btn-sel" : "btn btn-x"} title="Repetir" onClick={() => run("media.setLoop", { inputId: i.id, loop: !i.media!.loop })}>↻</button>
                <span className="muted small">{i.media.positionSeconds.toFixed(1)} / {i.media.durationSeconds.toFixed(1)} s</span>
              </span>
            )}
            {i.kind === "title" && (
              <button className="btn btn-x" title="Editar texto" onClick={async () => { const cfg = i.config as { template: string; fields?: Record<string, string> }; const cur = cfg.fields ?? {}; const f = await askFields(`Editar "${i.name}"`, Object.keys(cur).map((k) => ({ key: k, label: k, defaultValue: cur[k] }))); if (f) void run("title.setFields", { inputId: i.id, fields: f }); }}>✎</button>
            )}
            <button className="btn btn-x" title="Mudar nome" onClick={async () => { const name = await askText("Nome da fonte", "Nome", i.name); if (name) void run("input.update", { inputId: i.id, name }); }}>…</button>
            <button className="btn btn-x" title="Remover" onClick={() => { if (window.confirm(`Remover "${i.name}"?`)) void run("input.remove", { inputId: i.id }); }}>×</button>
          </li>
        ))}
        {inputs.length === 0 && <li className="muted">Sem fontes. Adicione uma fonte sintética para começar.</li>}
      </ul>
    </>
  );
}

// ---------------------------------------------------------------- Áudio

const dbOf = (v: number) => 20 * Math.log10(Math.max(v, 1e-5));
const pctOfDb = (db: number) => Math.max(0, Math.min(100, ((db + 60) / 60) * 100));

/** VU horizontal (miniaturas). */
export function Meter({ reading }: { reading?: MeterReading }) {
  return (
    <span className="meter" title={reading ? `${dbOf(reading.peakL).toFixed(1)} dBFS` : ""}>
      <span className="meter-bar" style={{ width: `${pctOfDb(dbOf(reading?.peakL ?? 0))}%` }} />
      <span className="meter-bar" style={{ width: `${pctOfDb(dbOf(reading?.peakR ?? 0))}%` }} />
    </span>
  );
}

const SCALE = [0, -6, -12, -18, -24, -36, -48, -60];

/** VU vertical com pico (true peak) e RMS, retenção de pico 1,5 s e escala em dBFS. */
function VMeter({ reading, id }: { reading?: MeterReading; id: string }) {
  const hold = useRef<Record<string, { db: number; at: number }>>({});
  const now = performance.now();
  const ch = (peak: number, rms: number, key: string) => {
    const pdb = dbOf(peak);
    const h = hold.current[key];
    if (!h || pdb >= h.db || now - h.at > 1500) hold.current[key] = { db: pdb, at: now };
    const hdb = hold.current[key].db;
    return (
      <span className="vmeter-ch">
        <span className="vmeter-rms" style={{ height: `${pctOfDb(dbOf(rms))}%` }} />
        <span className={pdb > -1 ? "vmeter-peak clip" : "vmeter-peak"} style={{ height: `${pctOfDb(pdb)}%` }} />
        <span className={hdb > -1 ? "vmeter-hold clip" : "vmeter-hold"} style={{ bottom: `${pctOfDb(hdb)}%` }} />
      </span>
    );
  };
  return (
    <span className="vmeter" title={reading ? `pico ${dbOf(reading.peakL).toFixed(1)} / ${dbOf(reading.peakR).toFixed(1)} dBFS` : "sem sinal"}>
      {ch(reading?.peakL ?? 0, reading?.rmsL ?? 0, id + "L")}
      {ch(reading?.peakR ?? 0, reading?.rmsR ?? 0, id + "R")}
      <span className="vmeter-scale">{SCALE.map((d) => <i key={d} style={{ bottom: `${pctOfDb(d)}%` }}>{d === 0 ? "0" : d}</i>)}</span>
    </span>
  );
}

function Fader({ db, onChange }: { db: number; onChange: (db: number) => void }) {
  return <input type="range" className="fader" min={-60} max={12} step={0.5} value={db} title={`${db.toFixed(1)} dB`} onChange={(e) => onChange(Number(e.target.value))} />;
}

/** Fader vertical: duplo clique repõe 0 dB; a roda ajusta 0,5 dB. */
function VFader({ db, onChange }: { db: number; onChange: (db: number) => void }) {
  return (
    <div className="vfader-wrap">
      <input type="range" className="vfader" min={-60} max={12} step={0.5} value={db} onChange={(e) => onChange(Number(e.target.value))} onDoubleClick={() => onChange(0)} onWheel={(e) => { e.preventDefault(); onChange(Math.max(-60, Math.min(12, db + (e.deltaY < 0 ? 0.5 : -0.5)))); }} />
    </div>
  );
}

const KIND_ICON: Record<string, string> = { media: "🎞", playlist: "📼", camera: "📷", screen: "🖥", ndi: "🌐", srt: "📡", audioDevice: "🎤", synthetic: "▦", title: "T", image: "🖼", decklink: "⬛" };

/** Mixer de áudio por channel strips (vMix/OBS): VU true-peak + RMS, fader vertical, pan, buses, AFV, plugins. */
export function AudioPanel({ run, meters }: { run: Run; meters: MeterReading[] }) {
  const engine = useStore((s) => s.engine);
  if (!engine) return null;
  const inputs = engine.inputOrder.map((id) => engine.inputs[id]).filter((i) => i && i.hasAudio);
  const silent = engine.inputOrder.map((id) => engine.inputs[id]).filter((i) => i && !i.hasAudio);
  const reading = (idx: number) => meters.find((m) => m.inputIndex === idx);
  const anySolo = Object.values(engine.audio.inputs).some((a) => a.solo);
  return (
    <div className="mixer">
      <div className="mixer-strips">
        {inputs.map((i) => {
          const a = engine.audio.inputs[i.id];
          const idx = engine.inputOrder.indexOf(i.id);
          const buses = a?.buses ?? ["master"];
          const db = a?.db ?? 0;
          const dimmed = anySolo && !a?.solo;
          return (
            <div key={i.id} className={dimmed ? "strip-ch dim" : "strip-ch"}>
              <div className="strip-name" title={i.name}><span className="ico">{KIND_ICON[i.kind] ?? "•"}</span>{i.name}</div>
              <div className="strip-plugins">
                {(a?.plugins ?? []).map((pl) => (
                  <span key={pl.id} className={pl.bypass ? "plugin-chip off" : "plugin-chip"}>
                    <button title={pl.bypass ? "Desligado (bypass): clique para ligar" : "Ligado: clique para bypass"} onClick={() => run("audio.setPluginBypass", { inputId: i.id, pluginId: pl.id, on: !pl.bypass })}>{pl.name}</button>
                    <button title="Parâmetros" onClick={() => void editPluginParams(run, i.id, pl.id, pl.name)}>⚙</button>
                    <button title="Remover" onClick={() => run("audio.removePlugin", { inputId: i.id, pluginId: pl.id })}>×</button>
                  </span>
                ))}
                <select className="plugin-add" value="" title="Adicionar plugin" onChange={(e) => { const v = e.target.value; e.target.value = ""; if (v) void run("audio.addPlugin", { inputId: i.id, componentId: v }); }}>
                  <option value="">+ plugin</option>
                  {engine.devices.audioUnits.map((u) => <option key={u.id} value={u.id}>{u.name}</option>)}
                </select>
              </div>
              <label className="strip-pan" title={`Pan ${a?.pan === 0 || !a ? "centro" : a.pan < 0 ? `E ${Math.round(-a.pan * 100)}%` : `D ${Math.round(a.pan * 100)}%`}`}>
                <span>E</span><input type="range" min={-1} max={1} step={0.05} value={a?.pan ?? 0} onChange={(e) => run("audio.setPan", { inputId: i.id, pan: Number(e.target.value) })} onDoubleClick={() => run("audio.setPan", { inputId: i.id, pan: 0 })} /><span>D</span>
              </label>
              <div className="strip-buses">
                {(["master", "a", "b"] as const).map((b) => (
                  <button key={b} className={buses.includes(b) ? "on" : ""} title={b === "master" ? "Envia para o Master" : `Envia para o Bus ${b.toUpperCase()}`} onClick={() => run("audio.setBus", { inputId: i.id, bus: b, on: !buses.includes(b) })}>{b === "master" ? "M" : b.toUpperCase()}</button>
                ))}
                <button className={a?.afv ? "on afv" : "afv"} title="Áudio segue vídeo: só se ouve quando a fonte está no ar" onClick={() => run("audio.setAFV", { inputId: i.id, on: !a?.afv })}>AFV</button>
              </div>
              <div className="strip-main">
                <VMeter reading={reading(idx)} id={i.id} />
                <VFader db={db} onChange={(v) => run("audio.setGain", { inputId: i.id, db: v })} />
              </div>
              <input className="strip-db" type="number" step={0.5} min={-60} max={12} value={db} onChange={(e) => run("audio.setGain", { inputId: i.id, db: Number(e.target.value) })} />
              <div className="strip-ms">
                <button className={a?.mute ? "mute on" : "mute"} title="Mute" onClick={() => run("audio.setMute", { inputId: i.id, on: !a?.mute })}>M</button>
                <button className={a?.solo ? "solo on" : "solo"} title="Solo (silencia os outros)" onClick={() => run("audio.setSolo", { inputId: i.id, on: !a?.solo })}>S</button>
              </div>
              <label className="strip-delay" title="Atraso para alinhar com o vídeo"><input type="number" min={0} max={2000} step={10} value={a?.delayMs ?? 0} onChange={(e) => run("audio.setDelay", { inputId: i.id, ms: Number(e.target.value) })} /> ms</label>
            </div>
          );
        })}
        {inputs.length === 0 && <div className="strip-empty muted">Sem fontes com áudio. Adicione um ficheiro, câmara, NDI ou um microfone (à direita).</div>}
        <div className="strip-sep" />
        {([["master", 255, "Master"], ["a", 254, "Bus A"], ["b", 253, "Bus B"]] as const).map(([bus, idx, label]) => (
          <div key={bus} className="strip-ch strip-bus">
            <div className="strip-name"><strong>{label}</strong></div>
            <div className="strip-plugins muted small">
              {bus === "master" ? "stream, gravação e NDI por omissão" : `${engine.audio.outputBus.stream === bus ? "stream · " : ""}${engine.audio.outputBus.ndi === bus ? "NDI · " : ""}${engine.audio.monitor.bus === bus ? "monitor" : ""}` || "livre"}
            </div>
            <div className="strip-buses">
              <button className={engine.audio.outputBus.stream === bus ? "on" : ""} title="Este barramento alimenta o stream e a gravação" onClick={() => run("audio.setOutputBus", { output: "stream", bus })}>Stream</button>
              <button className={engine.audio.outputBus.ndi === bus ? "on" : ""} title="Este barramento alimenta a saída NDI" onClick={() => run("audio.setOutputBus", { output: "ndi", bus })}>NDI</button>
              <button className={engine.audio.monitor.bus === bus ? "on" : ""} title="Ouvir este barramento nos auscultadores" onClick={() => run("audio.setMonitor", { bus })}>🎧</button>
            </div>
            <div className="strip-main"><VMeter reading={reading(idx)} id={bus} /></div>
            <div className="strip-ms">{bus === "master" && <button className={engine.audio.master.mute ? "mute on" : "mute"} onClick={() => run("audio.setMute", { inputId: "master", on: !engine.audio.master.mute })}>M</button>}</div>
          </div>
        ))}
      </div>
      <div className="mixer-foot">
        <label className="row"><span>Monitor</span>
          <select value={engine.audio.monitor.deviceId ?? ""} onChange={(e) => run("audio.setMonitor", { deviceId: e.target.value || null })}>
            <option value="">Dispositivo por omissão</option>
            {engine.devices.audioOut.map((d) => <option key={d.uid} value={d.uid}>{d.name}</option>)}
          </select>
        </label>
        <label className="row"><span>Microfone</span>
          <select value="" onChange={(e) => { const uid = e.target.value; e.target.value = ""; if (uid) { const d = engine.devices.audioIn.find((x) => x.uid === uid); void run("input.add", { kind: "audioDevice", name: d?.name ?? "Microfone", config: { uid } }); } }}>
            <option value="">+ adicionar entrada de áudio…</option>
            {engine.devices.audioIn.map((d) => <option key={d.uid} value={d.uid}>{d.name}</option>)}
          </select>
          <button className="btn btn-x" title="Procurar dispositivos" onClick={() => run("devices.refresh", {})}>↻</button>
        </label>
        {engine.audio.tuning?.enabled && <span className="tally on" title="Afinação global activa (Definições → Áudio)">432 Hz</span>}
        {silent.length > 0 && <span className="muted small">Sem áudio: {silent.map((i) => i.name).join(", ")}</span>}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- Saídas

export function OutputsPanel({ run }: { run: Run }) {
  const engine = useStore((s) => s.engine);
  if (!engine) return null;
  const outputs = Object.values(engine.outputs);
  const rec = engine.recording;
  const live = outputs.some((o) => o.status === "live") || rec.status === "recording";
  return (
    <>
      <h3>Destinos</h3>
      <div className="buttons">
        <button className="btn" onClick={async () => { const f = await askFields("Novo destino RTMP", [{ key: "url", label: "URL RTMP (sem a chave)", defaultValue: "rtmp://a.rtmp.youtube.com/live2" }, { key: "streamKey", label: "Chave de stream", defaultValue: "" }]); if (!f?.url) return; void run("output.add", { kind: "rtmp", name: f.url.replace(/^rtmps?:\/\//, "").split("/")[0], config: { url: f.url, streamKey: f.streamKey ?? "" } }); }}>+ RTMP</button>
        <button className="btn" onClick={async () => { const ndiName = await askText("Saída NDI", "Nome da fonte NDI", "WTV Studio"); if (ndiName) void run("output.add", { kind: "ndi", name: `NDI ${ndiName}`, config: { ndiName } }); }}>+ NDI</button>
        <button className="btn" onClick={async () => { const f = await askFields("Novo destino SRT", [{ key: "url", label: "URL (srt://host:porta para enviar, srt://:porta para esperar ligação)", defaultValue: "srt://127.0.0.1:9000" }, { key: "latency", label: "Latência (ms)", defaultValue: "120" }]); if (f?.url) void run("output.add", { kind: "srt", name: f.url.replace(/^srt:\/\//, ""), config: { url: f.url, latencyMs: Number(f.latency) || 120 } }); }}>+ SRT</button>
      </div>
      <ul className="lista small">
        {outputs.map((o) => (
          <li key={o.id}>
            <span className={`dot dot-${o.status === "live" ? "live" : o.status === "stopped" ? "idle" : o.status === "error" ? "error" : "starting"}`} title={o.statusCode ?? o.status} />
            <span className="nome">{o.name}</span>
            <span className="muted small">{o.kind}{o.config.url ? ` · ${o.config.url}` : ""}{o.config.ndiName ? ` · ${o.config.ndiName}` : ""} · {o.status}{o.statusCode ? ` · ${o.statusCode}` : ""}</span>
            <button
              className={o.status === "stopped" || o.status === "error" ? "btn btn-x btn-preview" : "btn btn-x btn-program"}
              onClick={() => {
                if (o.status === "stopped" || o.status === "error") void run("output.start", { outputId: o.id, txnId: newTxnId() });
                else if (window.confirm(`Parar "${o.name}"? A emissão para este destino termina.`)) void run("output.stop", { outputId: o.id, txnId: newTxnId() });
              }}
            >
              {o.status === "stopped" || o.status === "error" ? "Iniciar" : "Parar"}
            </button>
            {o.kind === "rtmp" && (o.status === "stopped" || o.status === "error") && (
              <button className="btn btn-x" title="Editar URL/chave" onClick={async () => { const f = await askFields("Editar destino", [{ key: "url", label: "URL RTMP", defaultValue: o.config.url ?? "" }, { key: "streamKey", label: "Chave de stream (vazio = manter)", defaultValue: "" }]); if (!f?.url) return; void run("output.update", { outputId: o.id, config: f.streamKey ? { url: f.url, streamKey: f.streamKey } : { url: f.url } }); }}>✎</button>
            )}
            {(o.status === "stopped" || o.status === "error") && <button className="btn btn-x" title="Remover" onClick={() => run("output.remove", { outputId: o.id })}>×</button>}
          </li>
        ))}
        {outputs.length === 0 && <li className="muted">Sem destinos. Adicione RTMP ou NDI.</li>}
      </ul>

      <h3>Gravação</h3>
      <div className="buttons">
        <button
          className={rec.status === "recording" ? "btn btn-program" : "btn"}
          disabled={rec.status === "starting" || rec.status === "stopping"}
          onClick={() => {
            if (rec.status === "recording") { if (window.confirm("Parar a gravação?")) void run("record.stop", { txnId: newTxnId() }); }
            else void run("record.start", { container: "mov", txnId: newTxnId() });
          }}
        >
          {rec.status === "recording" ? `● A gravar · ${((rec.bytes ?? 0) / 1e6).toFixed(0)} MB` : "● Gravar"}
        </button>
        {rec.file && <span className="muted small">{rec.file.split("/").pop()}</span>}
      </div>
      <label className="row">
        <span>Pasta</span>
        <span className="muted small" style={{ flex: 1, width: "auto" }}>{rec.folder ?? "~/Movies/WTV Studio"}</span>
        <button className="btn btn-x" onClick={async () => { const f = await pickFolder("Pasta de gravação"); if (f) void run("record.setFolder", { folder: f }); }}>Escolher…</button>
        {rec.folder && <button className="btn btn-x" title="Voltar à pasta por omissão" onClick={() => run("record.setFolder", { folder: null })}>×</button>}
      </label>
      <label className="row">
        <span>Formato</span>
        <select value={rec.container} onChange={(e) => run("record.setFolder", { folder: rec.folder ?? null, container: e.target.value })}>
          <option value="mov">.mov (fragmentado, recomendado)</option>
          <option value="mp4">.mp4</option>
        </select>
      </label>
      {live && <p className="muted small">Há saídas no ar: fechar a janela não as pára (o motor continua em segundo plano).</p>}
    </>
  );
}

// ---------------------------------------------------------------- Definições

const RASTERS = [
  { label: "1080p25", w: 1920, h: 1080, fps: 25 },
  { label: "1080p29.97", w: 1920, h: 1080, fps: 29.97 },
  { label: "1080p30", w: 1920, h: 1080, fps: 30 },
  { label: "1080p50", w: 1920, h: 1080, fps: 50 },
  { label: "1080p59.94", w: 1920, h: 1080, fps: 59.94 },
  { label: "1080p60", w: 1920, h: 1080, fps: 60 },
  { label: "2160p25", w: 3840, h: 2160, fps: 25 },
  { label: "2160p30", w: 3840, h: 2160, fps: 30 },
];

type SettingsPage = "video" | "saidas" | "gravacao" | "audio" | "projector" | "atalhos" | "rede" | "motor";
const PAGES: { id: SettingsPage; label: string; icon: string }[] = [
  { id: "video", label: "Vídeo", icon: "🎞" }, { id: "saidas", label: "Stream e codificação", icon: "📡" }, { id: "gravacao", label: "Gravação", icon: "⏺" },
  { id: "audio", label: "Áudio", icon: "🎚" }, { id: "projector", label: "Projector", icon: "🖥" }, { id: "atalhos", label: "Atalhos", icon: "⌨" },
  { id: "rede", label: "Rede e dispositivos", icon: "🌐" }, { id: "motor", label: "Motor e registo", icon: "⚙" },
];
const SHORTCUTS: [string, string][] = [["1–9", "Fonte N para Preview"], ["Enter", "Cut"], ["Espaço", "Fade (duração da coluna)"], ["F", "Fade to black"], ["Esc", "Fechar janela / projector"], ["Duplo clique na miniatura", "Cut directo"]];

/** Painel de definições com barra lateral, à maneira do vMix (categorias) e do OBS (páginas); só mostra o que o motor suporta. */
export function SettingsPanel({ run, engineUrl }: { run: Run; engineUrl: string }) {
  const engine = useStore((s) => s.engine);
  const log = useStore((s) => s.log);
  const [page, setPage] = useState<SettingsPage>("video");
  if (!engine) return null;
  const live = Object.values(engine.outputs).some((o) => o.status !== "stopped") || engine.recording.status !== "idle";
  const enc = engine.project.encoding ?? { videoBitrateKbps: 6000, audioBitrateKbps: 160, keyintSec: 2, profile: "high", rateControl: "CBR" };
  const r = engine.project.raster;
  const current = RASTERS.find((x) => x.w === r.width && x.h === r.height && x.fps === r.fps)?.label ?? `${r.width}×${r.height}@${r.fps}`;
  const lock = live ? "Pare as saídas e a gravação para alterar" : "";
  const setEnc = (patch: Partial<typeof enc>) => void run("project.setEncoding", patch);
  const mbps = (enc.videoBitrateKbps + enc.audioBitrateKbps) / 1000;

  return (
    <div className="settings">
      <nav className="settings-nav">
        {PAGES.map((p) => <button key={p.id} className={page === p.id ? "on" : ""} onClick={() => setPage(p.id)}><span className="ico">{p.icon}</span>{p.label}</button>)}
      </nav>
      <div className="settings-page">
        {page === "video" && (
          <>
            <h3>Formato de produção</h3>
            <p className="hint">Resolução e cadência do Program, do preview e de todas as saídas. Igual ao "Output Size" do vMix e ao "Base/Output" do OBS, mas um só formato: o motor codifica uma vez e envia para todos os destinos.</p>
            <label className="row"><span>Formato</span>
              <select value={current} disabled={live} title={lock} onChange={(e) => { const x = RASTERS.find((y) => y.label === e.target.value); if (x) void run("project.setRaster", { width: x.w, height: x.h, fps: x.fps }); }}>
                {RASTERS.map((x) => <option key={x.label} value={x.label}>{x.label}</option>)}
                {!RASTERS.some((x) => x.label === current) && <option value={current}>{current}</option>}
              </select>
              {live && <span className="muted small">{lock}</span>}
            </label>
            <h3>Multiview</h3>
            <label className="row"><span>Disposição</span>
              <select value={engine.multiview.layoutId} onChange={(e) => run("preview.setLayout", { layoutId: e.target.value })}>
                <option value="2+8">Preview + Program + 8 fontes</option>
                <option value="2+16">Preview + Program + 16 fontes</option>
                <option value="pgm+pvw">Só Preview e Program</option>
              </select>
            </label>
            <p className="hint">O preview da interface é um único stream H.264 {engine.multiview.size.width}×{engine.multiview.size.height} descodificado no browser; as miniaturas são recortes dele.</p>
            <h3>Renderização</h3>
            <ul className="lista small">
              <li><span className="nome">Compositor</span> libobs · Metal (Apple Silicon)</li>
              <li><span className="nome">Codificador</span> VideoToolbox H.264 por hardware · {engine.budget.encoderUsedPercent.toFixed(0)} % de {engine.budget.encoderCapacity1080pFps} fps 1080p</li>
              <li><span className="nome">Memória</span> {engine.budget.memoryUsedMB} MB de {engine.budget.memoryLimitMB} MB reservados ao motor</li>
            </ul>
          </>
        )}
        {page === "saidas" && (
          <>
            <h3>Codificação de Program</h3>
            <p className="hint">Um codificador para stream e gravação (encode-once). Para YouTube/Facebook a 1080p50 use 6 000–9 000 kbps; keyframe de 2 s é o exigido pelas plataformas.</p>
            <label className="row"><span>Bitrate vídeo</span><input type="number" min={500} max={60000} step={250} value={enc.videoBitrateKbps} disabled={live} title={lock} onChange={(e) => setEnc({ videoBitrateKbps: Number(e.target.value) })} /> <span className="muted small">kbps</span></label>
            <label className="row"><span>Bitrate áudio</span>
              <select value={enc.audioBitrateKbps} disabled={live} title={lock} onChange={(e) => setEnc({ audioBitrateKbps: Number(e.target.value) })}>
                {[96, 128, 160, 192, 256, 320].map((b) => <option key={b} value={b}>{b} kbps AAC</option>)}
              </select>
            </label>
            <label className="row"><span>Keyframe</span>
              <select value={enc.keyintSec} disabled={live} title={lock} onChange={(e) => setEnc({ keyintSec: Number(e.target.value) })}>
                {[1, 2, 3, 4].map((k) => <option key={k} value={k}>{k} s</option>)}
              </select>
            </label>
            <label className="row"><span>Perfil</span>
              <select value={enc.profile} disabled={live} title={lock} onChange={(e) => setEnc({ profile: e.target.value as typeof enc.profile })}>
                <option value="high">High (recomendado)</option><option value="main">Main</option><option value="baseline">Baseline (compatibilidade)</option>
              </select>
            </label>
            <label className="row"><span>Controlo</span>
              <select value={enc.rateControl} disabled={live} title={lock} onChange={(e) => setEnc({ rateControl: e.target.value as typeof enc.rateControl })}>
                <option value="CBR">CBR (constante, para stream)</option><option value="VBR">VBR (variável)</option>
              </select>
            </label>
            <p className="hint">Total ≈ {mbps.toFixed(1)} Mbps por destino · {Object.keys(engine.outputs).length} destino(s) configurado(s) em "Saídas".</p>
            <h3>Barramentos das saídas</h3>
            <label className="row"><span>Stream + gravação</span>
              <select value={engine.audio.outputBus.stream} disabled={live} title={lock} onChange={(e) => run("audio.setOutputBus", { output: "stream", bus: e.target.value })}>
                <option value="master">Master</option><option value="a">Bus A</option><option value="b">Bus B</option>
              </select>
            </label>
            <label className="row"><span>NDI</span>
              <select value={engine.audio.outputBus.ndi} onChange={(e) => run("audio.setOutputBus", { output: "ndi", bus: e.target.value })}>
                <option value="master">Master</option><option value="a">Bus A</option><option value="b">Bus B</option>
              </select>
            </label>
          </>
        )}
        {page === "gravacao" && (
          <>
            <h3>Gravação local</h3>
            <label className="row"><span>Pasta</span>
              <span className="path">{engine.recording.folder ?? "~/Movies/WTV Studio"}</span>
              <button className="btn btn-x" disabled={engine.recording.status !== "idle"} onClick={async () => { const f = await pickFolder("Pasta de gravação"); if (f) void run("record.setFolder", { folder: f }); }}>Escolher…</button>
              {engine.recording.folder && <button className="btn btn-x" disabled={engine.recording.status !== "idle"} onClick={() => run("record.setFolder", { folder: null })}>Predefinida</button>}
            </label>
            <label className="row"><span>Contentor</span>
              <select value={engine.recording.container} disabled={engine.recording.status !== "idle"} onChange={(e) => run("record.setFolder", { folder: engine.recording.folder ?? null, container: e.target.value })}>
                <option value="mp4">MP4 (universal)</option><option value="mov">MOV (Final Cut / Premiere)</option>
              </select>
            </label>
            <p className="hint">Ficheiros "WTV AAAA-MM-DD HH-MM-SS" com a codificação da página "Stream e codificação". A gravação usa o mesmo H.264/AAC do stream, sem segunda codificação.</p>
            {engine.recording.status !== "idle" && <p className="hint">A gravar para <code>{engine.recording.file}</code> desde {engine.recording.startedAt && new Date(engine.recording.startedAt).toLocaleTimeString("pt-PT")}.</p>}
          </>
        )}
        {page === "audio" && (
          <>
            <h3>Dispositivo e monitorização</h3>
            <ul className="lista small"><li><span className="nome">Motor</span> 48 kHz · float 32 bits · estéreo · blocos de 10 ms</li></ul>
            <label className="row"><span>Monitor</span>
              <select value={engine.audio.monitor.deviceId ?? ""} onChange={(e) => run("audio.setMonitor", { deviceId: e.target.value || null })}>
                <option value="">Predefinido do sistema</option>
                {engine.devices.audioOut.map((d) => <option key={d.uid} value={d.uid}>{d.name}</option>)}
              </select>
              <select value={engine.audio.monitor.bus} onChange={(e) => run("audio.setMonitor", { bus: e.target.value })}>
                <option value="master">ouve o Master</option><option value="a">ouve o Bus A</option><option value="b">ouve o Bus B</option>
              </select>
            </label>
            <h3>Afinação 432 Hz</h3>
            <p className="hint">Baixa a afinação de todas as fontes de 440 Hz para 432 Hz (−31,77 cents) sem alterar a velocidade. Aplica-se automaticamente a cada canal, incluindo os que forem adicionados depois; acrescenta cerca de 40 ms de latência ao áudio.</p>
            <label className="row"><span>Afinação global</span>
              <button className={engine.audio.tuning?.enabled ? "btn btn-on" : "btn"} onClick={() => run("audio.setTuning", { on: !engine.audio.tuning?.enabled, cents: engine.audio.tuning?.cents ?? -31.766533 })}>{engine.audio.tuning?.enabled ? "432 Hz ligado" : "440 Hz (desligado)"}</button>
            </label>
            <label className="row"><span>Desvio</span>
              <select value={String(engine.audio.tuning?.cents ?? -31.766533)} onChange={(e) => run("audio.setTuning", { on: engine.audio.tuning?.enabled ?? false, cents: Number(e.target.value) })}>
                <option value="-31.766533">432 Hz (−31,77 cents)</option>
                <option value="-70.672">422,5 Hz barroco (−70,67 cents)</option>
                <option value="-15.6413">436 Hz (−15,64 cents)</option>
                <option value="15.6413">444 Hz (+15,64 cents)</option>
              </select>
              <input type="number" step={0.01} min={-200} max={200} value={engine.audio.tuning?.cents ?? -31.766533} onChange={(e) => run("audio.setTuning", { on: engine.audio.tuning?.enabled ?? false, cents: Number(e.target.value) })} /> <span className="muted small">cents</span>
            </label>
            <h3>Matriz de barramentos</h3>
            <p className="hint">Como no vMix: cada fonte envia para Master, A e B. A e B servem para mix-minus (retorno sem o próprio apresentador) ou para o NDI levar um áudio diferente do stream.</p>
            <table className="matrix">
              <thead><tr><th>Fonte</th><th>M</th><th>A</th><th>B</th><th>AFV</th><th>Ganho</th></tr></thead>
              <tbody>
                {engine.inputOrder.map((id) => { const i = engine.inputs[id]; const a = engine.audio.inputs[id]; if (!i?.hasAudio) return null; const buses = a?.buses ?? ["master"]; return (
                  <tr key={id}><td>{i.name}</td>
                    {(["master", "a", "b"] as const).map((b) => <td key={b}><input type="checkbox" checked={buses.includes(b)} onChange={(e) => run("audio.setBus", { inputId: id, bus: b, on: e.target.checked })} /></td>)}
                    <td><input type="checkbox" checked={a?.afv ?? true} onChange={(e) => run("audio.setAFV", { inputId: id, on: e.target.checked })} /></td>
                    <td className="muted small">{(a?.db ?? 0).toFixed(1)} dB</td>
                  </tr>); })}
                {!engine.inputOrder.some((id) => engine.inputs[id]?.hasAudio) && <tr><td colSpan={6} className="muted">Sem fontes com áudio.</td></tr>}
              </tbody>
            </table>
            <p className="hint">Plugins (RNNoise, compressor, EQ…) e faders estão no Audio Mixer.</p>
          </>
        )}
        {page === "projector" && (
          <>
            <h3>Projector</h3>
            <p className="hint">Saída para um ecrã ou projector físico. Em ecrãs externos abre em ecrã inteiro; no ecrã principal abre sempre em janela (Esc fecha).</p>
            <div className="buttons">
              <button className={engine.projector.displayId ? "btn" : "btn btn-sel"} onClick={() => run("projector.set", { displayId: null })}>Desligado</button>
              {engine.devices.displays.map((d) => (
                <button key={d.id} className={engine.projector.displayId === d.id ? "btn btn-sel" : "btn"} title={d.isMain ? "Ecrã principal: abre sempre em janela" : ""} onClick={() => run("projector.set", { displayId: d.id, source: engine.projector.source, fullscreen: !d.isMain })}>{d.name} · {d.width}×{d.height} @ {Math.round(d.refreshHz)} Hz{d.isMain ? " (principal)" : ""}</button>
              ))}
            </div>
            <label className="row"><span>Conteúdo</span>
              <select value={engine.projector.source} onChange={(e) => run("projector.set", { displayId: engine.projector.displayId, source: e.target.value, fullscreen: engine.projector.fullscreen })}>
                <option value="program">Program</option><option value="multiview">Multiview</option>
                {engine.inputOrder.map((id) => <option key={id} value={id}>Fonte: {engine.inputs[id]?.name}</option>)}
              </select>
            </label>
            <div className="buttons">
              <button className={engine.projector.fullscreen ? "btn btn-sel" : "btn"} disabled={!engine.devices.displays.some((d) => !d.isMain)} title="Só em ecrãs externos" onClick={() => run("projector.set", { displayId: engine.projector.displayId, source: engine.projector.source, fullscreen: !engine.projector.fullscreen })}>Ecrã inteiro</button>
            </div>
          </>
        )}
        {page === "atalhos" && (
          <>
            <h3>Atalhos de teclado</h3>
            <table className="matrix"><tbody>{SHORTCUTS.map(([k, d]) => <tr key={k}><td><kbd>{k}</kbd></td><td>{d}</td></tr>)}</tbody></table>
            <p className="hint">Atalhos personalizados, MIDI e Stream Deck ficam para uma versão seguinte.</p>
          </>
        )}
        {page === "rede" && (
          <>
            <h3>Acesso</h3>
            <ul className="lista small">
              <li><span className="nome">Motor</span> {engineUrl} · {engine.system.remoteAccess ? "acesso remoto ligado" : "só neste Mac (token por arranque, cookie de sessão)"}</li>
              <li><span className="nome">Capacidades</span> NDI {engine.devices.ndiSources ? "sim" : "não"} · SRT sim · DeckLink não</li>
            </ul>
            <p className="hint">Controlo a partir de outro computador ou tablet (PIN + QR) fica para a fase de acesso LAN.</p>
            <h3>Fontes NDI na rede <button className="btn btn-x" onClick={() => run("devices.refresh", {})}>Actualizar</button></h3>
            <ul className="lista small">
              {engine.devices.ndiSources.map((n) => <li key={n.name}><span className="nome">NDI</span> {n.name} <span className="muted">{n.url}</span></li>)}
              {engine.devices.ndiSources.length === 0 && <li className="muted">Nenhuma fonte NDI encontrada.</li>}
            </ul>
            <h3>Ecrãs</h3>
            <ul className="lista small">{engine.devices.displays.map((d) => <li key={d.id}><span className="nome">{d.isMain ? "Principal" : "Externo"}</span> {d.name} · {d.width}×{d.height} @ {Math.round(d.refreshHz)} Hz</li>)}</ul>
            <h3>Saídas de áudio</h3>
            <ul className="lista small">{engine.devices.audioOut.map((d) => <li key={d.uid}><span className="nome">{d.isDefault ? "Predefinida" : "Saída"}</span> {d.name}</li>)}</ul>
          </>
        )}
        {page === "motor" && (
          <>
            <h3>Motor</h3>
            <ul className="lista small">
              <li><span className="nome">Versão</span> {engine.system.engineVersion} · pid {engine.system.pid} · desde {new Date(engine.system.startedAt).toLocaleTimeString("pt-PT")}</li>
              <li><span className="nome">Térmico</span> {engine.system.thermal}</li>
              <li><span className="nome">Permissões</span> câmara {engine.permissions.camera} · microfone {engine.permissions.microphone} · ecrã {engine.permissions.screen}</li>
            </ul>
            <div className="buttons">
              <button className="btn" onClick={() => { if (window.confirm("Encerrar o motor? Todas as saídas param.")) void run("engine.shutdown", { force: true }); }}>Encerrar motor</button>
            </div>
            {engine.alarms.length > 0 && (<><h3>Alarmes</h3><ul className="lista small">{engine.alarms.map((a) => <li key={a.id} className={a.level === "critical" ? "erro" : ""}>{a.detail ?? a.code}</li>)}</ul></>)}
            <h3>Registo</h3>
            <ul className="lista small">
              {log.slice(-20).reverse().map((l, i) => <li key={i}><span className="muted">{new Date(l.at).toLocaleTimeString("pt-PT")}</span> {l.message}</li>)}
              {log.length === 0 && <li className="muted">Sem eventos.</li>}
            </ul>
          </>
        )}
      </div>
    </div>
  );
}

const fmtTime = (t: number) => { const s = Math.max(0, Math.floor(t)); return `${String(Math.floor(s / 3600)).padStart(2, "0")}:${String(Math.floor((s % 3600) / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`; };

/** Playout: lista de reprodução encadeada (uma fonte "playlist"), com pontos in/out e importação ffplayout. */
export function PlayoutPanel({ run }: { run: Run }) {
  const engine = useStore((s) => s.engine);
  if (!engine) return null;
  const lists = engine.inputOrder.filter((id) => engine.inputs[id]?.kind === "playlist");
  const [sel, setSel] = useState<string | null>(null);
  const id = sel && lists.includes(sel) ? sel : lists[0] ?? null;
  const input = id ? engine.inputs[id] : null;
  const cfg = (input?.config ?? { items: [], index: 0, loopList: true }) as PlaylistConfig;
  const media = input?.media;
  const total = cfg.items.reduce((acc, it) => acc + ((it.out > 0 ? it.out : it.duration ?? 0) - it.in), 0);
  const remaining = media && cfg.items[cfg.index] ? ((cfg.items[cfg.index].out > 0 ? cfg.items[cfg.index].out : media.durationSeconds) - media.positionSeconds) : 0;
  const onAir = id && (engine.program.inputId === id);
  return (
    <div className="playout">
      <div className="buttons">
        {lists.map((l) => <button key={l} className={l === id ? "btn btn-sel" : "btn"} onClick={() => setSel(l)}>{engine.inputs[l].name}</button>)}
        <button className="btn" onClick={async () => { const name = await askText("Novo Playout", "Nome", "Playout"); if (name) void run("input.add", { kind: "playlist", name, config: { items: [], index: 0, loopList: true } }); }}>+ Novo Playout</button>
      </div>
      {!input && <p className="hint">Um Playout é uma fonte normal (aparece nas miniaturas, vai para Preview/Program) que toca uma lista de ficheiros em sequência, como uma grelha de emissão. Crie um e adicione ficheiros.</p>}
      {input && id && (
        <>
          <div className="playout-now">
            <span className={onAir ? "tally on" : "tally"}>{onAir ? "NO AR" : "fora do ar"}</span>
            <strong>{cfg.items[cfg.index]?.name ?? "—"}</strong>
            <span className="muted">{media ? `${fmtTime(media.positionSeconds)} / ${fmtTime(cfg.items[cfg.index]?.out || media.durationSeconds)}` : ""}</span>
            <span className={remaining > 0 && remaining < 10 ? "erro" : "muted"}>restam {fmtTime(remaining)}</span>
            <span className="spacer" />
            <button className="btn btn-x" onClick={() => run("media.play", { inputId: id })}>▶</button>
            <button className="btn btn-x" onClick={() => run("media.pause", { inputId: id })}>⏸</button>
            <button className="btn btn-x" title="Seguinte" onClick={() => run("playlist.next", { inputId: id })}>⏭</button>
            <button className={cfg.loopList ? "btn btn-x btn-sel" : "btn btn-x"} title="Repetir a lista no fim" onClick={() => run("playlist.setLoop", { inputId: id, on: !cfg.loopList })}>⟲ lista</button>
          </div>
          <table className="matrix playout-list">
            <thead><tr><th>#</th><th>Ficheiro</th><th>In</th><th>Out</th><th>Duração</th><th></th></tr></thead>
            <tbody>
              {cfg.items.map((it, i) => (
                <tr key={i} className={i === cfg.index ? "current" : ""} onDoubleClick={() => run("playlist.jump", { inputId: id, index: i })}>
                  <td>{i + 1}</td>
                  <td title={it.path}>{i === cfg.index ? "▶ " : ""}{it.name}</td>
                  <td><input className="tiny" type="number" min={0} step={0.5} value={it.in} onChange={(e) => run("playlist.setItem", { inputId: id, index: i, in: Number(e.target.value) })} /></td>
                  <td><input className="tiny" type="number" min={0} step={0.5} value={it.out} title="0 = até ao fim" onChange={(e) => run("playlist.setItem", { inputId: id, index: i, out: Number(e.target.value) })} /></td>
                  <td className="muted">{it.duration ? fmtTime(it.duration) : "—"}</td>
                  <td>
                    <button className="btn btn-x" title="Tocar já" onClick={() => run("playlist.jump", { inputId: id, index: i })}>▶</button>
                    <button className="btn btn-x" title="Subir" disabled={i === 0} onClick={() => run("playlist.move", { inputId: id, from: i, to: i - 1 })}>↑</button>
                    <button className="btn btn-x" title="Descer" disabled={i === cfg.items.length - 1} onClick={() => run("playlist.move", { inputId: id, from: i, to: i + 1 })}>↓</button>
                    <button className="btn btn-x" title="Remover" onClick={() => run("playlist.remove", { inputId: id, index: i })}>×</button>
                  </td>
                </tr>
              ))}
              {cfg.items.length === 0 && <tr><td colSpan={6} className="muted">Lista vazia.</td></tr>}
            </tbody>
          </table>
          <div className="buttons">
            <button className="btn" onClick={async () => { const paths = await pickFiles("video"); if (paths.length) void run("playlist.add", { inputId: id, paths }); }}>+ Ficheiros…</button>
            <button className="btn" onClick={async () => { const paths = await pickFiles("any", false); if (paths[0]) void run("playlist.import", { inputId: id, path: paths[0] }); }}>Importar playlist (ffplayout JSON)…</button>
            <button className="btn" onClick={async () => { const folder = await pickFolder("Pasta para exportar"); if (folder) void run("playlist.export", { inputId: id, path: `${folder}/${cfg.date || new Date().toISOString().slice(0, 10)}.json` }); }}>Exportar…</button>
            <span className="spacer" />
            <span className="muted small">{cfg.items.length} item(s) · {fmtTime(total)} no total</span>
          </div>
          <p className="hint">Formato de playlist igual ao do ffplayout: cada item tem in, out (0 = fim do ficheiro) e source. Quando um ficheiro acaba ou chega ao out, passa ao seguinte; com "⟲ lista" volta ao início.</p>
        </>
      )}
    </div>
  );
}
