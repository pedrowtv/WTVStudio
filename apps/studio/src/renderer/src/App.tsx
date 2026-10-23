import { useCallback, useEffect, useState } from "react";
import type { MeterReading } from "@wtv/protocol";
import { useStore } from "./store";
import { RpcDomainError, newTxnId } from "./rpc";
import { PreviewClient } from "./preview";
import { frameRouter } from "./frames";
import { Monitor } from "./components/Monitor";
import { TransitionColumn } from "./components/TransitionColumn";
import { InputStrip } from "./components/InputStrip";
import { Overlays } from "./components/Overlays";
import { AudioPanel, OutputsPanel, SettingsPanel, SourcesPanel } from "./components/panels";
import { askFields, askText, finishPrompt, pickFiles, usePromptHost } from "./dialogs";

const ERROS: Record<string, string> = {
  INPUT_NOT_FOUND: "Fonte não encontrada",
  OUTPUT_NOT_FOUND: "Saída não encontrada",
  INVALID_PARAMS: "Parâmetros inválidos",
  ENCODER_BUDGET: "Excede a capacidade do codificador",
  MEMORY_BUDGET: "Excede a memória disponível",
  DEVICE_UNAVAILABLE: "Dispositivo indisponível",
  PERMISSION_DENIED: "Permissão negada",
  ALREADY_RUNNING: "Já está a correr",
  NOT_RUNNING: "Não está a correr",
  DISK_FULL: "Disco cheio",
  CAPABILITY_MISSING: "Funcionalidade indisponível nesta versão",
  UNAUTHORIZED: "Não autorizado",
  METHOD_NOT_FOUND: "Comando desconhecido",
};

function traduz(e: unknown): string {
  if (e instanceof RpcDomainError) return `${ERROS[e.code] ?? e.code}${e.detail ? ` (${e.detail})` : ""}`;
  return String(e);
}

type Modal = null | "fontes" | "audio" | "saidas" | "definicoes" | "overlays";
const TITULOS: Record<Exclude<Modal, null>, string> = { fontes: "Fontes", audio: "Audio Mixer", saidas: "Saídas", definicoes: "Definições", overlays: "Overlays" };

export function App({ engineUrl, token }: { engineUrl: string; token: string | null }) {
  const connection = useStore((s) => s.connection);
  const engine = useStore((s) => s.engine);
  const client = useStore((s) => s.client);
  const [erro, setErro] = useState<string | null>(null);
  const [modal, setModal] = useState<Modal>(null);
  const [meters, setMeters] = useState<MeterReading[]>([]);
  const [previewStatus, setPreviewStatus] = useState("a ligar…");
  const prompt = usePromptHost();

  const run = useCallback(
    async (method: string, params?: unknown): Promise<unknown> => {
      setErro(null);
      try {
        return await client?.call(method, params);
      } catch (e) {
        setErro(traduz(e));
        return undefined;
      }
    },
    [client],
  );

  // Um descodificador para toda a interface; os canvases subscrevem os tiles.
  useEffect(() => {
    if (!PreviewClient.supported()) {
      setPreviewStatus("WebCodecs indisponível (abra via http://localhost ou na app)");
      return;
    }
    const p = new PreviewClient({ baseUrl: engineUrl, token, stream: "multiview", onFrame: (f) => frameRouter.draw(f), onMeters: setMeters, onStatus: setPreviewStatus });
    p.connect();
    return () => p.close();
  }, [engineUrl, token]);

  useEffect(() => {
    frameRouter.setTiles(engine?.multiview.tiles ?? []);
  }, [engine?.multiview.tiles]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setModal(null);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const outputs = Object.values(engine?.outputs ?? {});
  const liveOutputs = outputs.filter((o) => o.status === "live").length;
  const streaming = outputs.some((o) => o.kind === "rtmp" && o.status !== "stopped");
  const recording = engine?.recording.status === "recording";
  const critical = engine?.alarms.filter((a) => a.level === "critical") ?? [];
  const master = meters.find((m) => m.inputIndex === 255);
  const masterDb = master ? 20 * Math.log10(Math.max(master.peakL, 1e-5)) : -60;
  const inputCount = engine?.inputOrder.length ?? 0;
  const addQuick = (kind: string, config: unknown, name?: string) => run("input.add", { kind, name, config });

  return (
    <div className="app">
      <header className="toolbar">
        <div className="toolbar-group">
          <span className="brand">WTV Studio</span>
          <button className="btn" onClick={async () => { const name = await askText("Guardar projecto", "Nome do projecto", engine?.project.name && engine.project.name !== "Sem título" ? engine.project.name : ""); if (name) void run("project.save", { path: name }); }}>Guardar</button>
          <button
            className="btn"
            onClick={async () => {
              let list: string[] = [];
              try { list = ((await client?.call("project.list")) as string[]) ?? []; } catch { /* sem lista */ }
              const name = await askText("Abrir projecto", list.length ? `Nome do projecto (existentes: ${list.map((n) => n.replace(".wtv.json", "")).join(", ")})` : "Nome do projecto", "");
              if (name) void run("project.load", { path: name });
            }}
          >
            Abrir
          </button>
        </div>
        <div className="toolbar-group">
          <button
            className={engine?.projector.displayId ? "btn btn-on" : "btn"}
            onClick={() => {
              if (engine?.projector.displayId) { void run("projector.set", { displayId: null }); return; }
              const external = engine?.devices.displays.find((x) => !x.isMain);
              if (external) {
                void run("projector.set", { displayId: external.id, source: "program", fullscreen: true });
              } else {
                const main = engine?.devices.displays[0];
                if (!main) return;
                // Só há um ecrã: abre em janela (nunca tapa a interface). Esc fecha a janela.
                void run("projector.set", { displayId: main.id, source: "program", fullscreen: false });
              }
            }}
            title={engine?.devices.displays.some((x) => !x.isMain) ? "Projector em ecrã inteiro no ecrã externo" : "Só há um ecrã: o projector abre em janela (Esc fecha)"}
          >
            {engine?.projector.displayId ? "Fechar projector" : engine?.devices.displays.some((x) => !x.isMain) ? "Ecrã inteiro" : "Projector (janela)"}
          </button>
        </div>
        <div className="toolbar-group">
          <span className={`pill pill-${connection}`}>
            {connection === "connected" && `Motor ${engine?.system.engineVersion ?? ""}`}
            {connection === "connecting" && "A ligar…"}
            {connection === "disconnected" && "Sem motor"}
          </span>
          {recording && <span className="pill pill-rec">● REC</span>}
          {liveOutputs > 0 && <span className="pill pill-live">NO AR · {liveOutputs}</span>}
          {engine?.program.ftb && <span className="pill pill-rec">FTB</span>}
          <button className="btn" onClick={() => setModal("definicoes")}>Definições</button>
        </div>
      </header>

      {erro && <div className="banner banner-erro" onClick={() => setErro(null)}>{erro}</div>}
      {critical.map((a) => <div key={a.id} className="banner banner-erro">{a.detail ?? a.code}</div>)}
      {connection === "disconnected" && <div className="banner banner-aviso">Sem ligação ao motor. A emissão continua se o motor estiver a correr; a reconectar…</div>}

      <main className="stage">
        <Monitor bus="preview" run={run} />
        <TransitionColumn run={run} />
        <Monitor bus="program" run={run} />
      </main>

      <div className="strip-bar">
        <span className="muted small">Fontes ({inputCount}) · clique = Preview · duplo clique = Cut · teclas 1–9, Enter, Espaço, F</span>
        <span className="spacer" />
        <button className="btn" onClick={() => setModal("audio")}>
          🔊 Audio Mixer <span className="mini-meter"><span style={{ width: `${Math.max(0, Math.min(100, ((masterDb + 60) / 60) * 100))}%` }} /></span>
        </button>
      </div>
      <InputStrip run={run} />

      <footer className="bottombar">
        <div className="btn-split">
          <button className="btn btn-wide" onClick={() => setModal("fontes")}>Adicionar fonte</button>
          <select
            className="quick-add"
            value=""
            onChange={(e) => {
              const v = e.target.value;
              e.target.value = "";
              if (v === "bars") void addQuick("synthetic", { pattern: "bars", tone: true }, "Barras");
              if (v === "colour") void addQuick("synthetic", { pattern: "colour", colour: "#2060c0" }, "Cor");
              if (v === "screen") void addQuick("screen", { audio: false, showCursor: true }, "Ecrã");
              if (v === "media") void pickFiles("video").then((paths) => paths.forEach((path) => void addQuick("media", { path, speed: 1 })));
              if (v === "image") void pickFiles("image").then((paths) => paths.forEach((path) => void addQuick("image", { path })));
              if (v === "title") void askFields("Novo oráculo", [{ key: "name", label: "Nome" }, { key: "role", label: "Função / cargo", defaultValue: "WayTV" }]).then((f) => { if (f?.name) void addQuick("title", { template: "lowerThird", fields: { name: f.name, role: f.role ?? "" } }, "Oráculo"); });
            }}
          >
            <option value="">▴</option>
            <option value="media">Ficheiro de vídeo/áudio…</option>
            <option value="image">Imagem…</option>
            <option value="title">Oráculo…</option>
            <option value="screen">Ecrã</option>
            <option value="bars">Barras + tom</option>
            <option value="colour">Cor</option>
          </select>
        </div>
        <div className="btn-split">
          <button className="btn btn-icon" title="Definições de gravação" onClick={() => setModal("saidas")}>⚙</button>
          <button className={recording ? "btn btn-wide btn-program" : "btn btn-wide"} onClick={() => { if (recording) { if (window.confirm("Parar a gravação?")) void run("record.stop", { txnId: newTxnId() }); } else void run("record.start", { container: "mov", txnId: newTxnId() }); }}>
            {recording ? `● Gravar · ${((engine?.recording.bytes ?? 0) / 1e6).toFixed(0)} MB` : "Gravar"}
          </button>
        </div>
        <div className="btn-split">
          <button className="btn btn-icon" title="Definições de stream" onClick={() => setModal("saidas")}>⚙</button>
          <button
            className={streaming ? "btn btn-wide btn-program" : "btn btn-wide"}
            onClick={() => {
              const rtmp = outputs.filter((o) => o.kind === "rtmp");
              if (rtmp.length === 0) { setModal("saidas"); return; }
              if (streaming) { if (window.confirm("Parar o stream?")) rtmp.filter((o) => o.status !== "stopped").forEach((o) => void run("output.stop", { outputId: o.id, txnId: newTxnId() })); }
              else if (window.confirm(`Iniciar o stream para ${rtmp.length} destino(s): ${rtmp.map((o) => o.name).join(", ")}?`)) rtmp.forEach((o) => void run("output.start", { outputId: o.id, txnId: newTxnId() }));
            }}
          >
            {streaming ? "● Stream" : "Stream"}
          </button>
        </div>
        <button className="btn btn-wide" onClick={() => setModal("saidas")}>Externo (NDI)</button>
        <button className="btn btn-wide" onClick={() => setModal("overlays")}>Overlay</button>
        <span className="spacer" />
        <span className="status">
          <strong className="status-format">{engine ? `${engine.project.raster.height}p${engine.project.raster.fps}` : "—"}</strong>
          <span>Preview: {previewStatus}</span>
          <span>Codificador: {engine?.budget.encoderUsedPercent.toFixed(0) ?? 0}%</span>
          <span>Térmico: {engine?.system.thermal ?? "—"}</span>
        </span>
      </footer>

      {prompt && (
        <div className="modal-backdrop" onClick={() => finishPrompt(prompt, null)}>
          <form
            className="modal modal-prompt"
            onClick={(e) => e.stopPropagation()}
            onSubmit={(e) => {
              e.preventDefault();
              const data = new FormData(e.currentTarget);
              const values: Record<string, string> = {};
              for (const f of prompt.fields ?? []) values[f.key] = String(data.get(f.key) ?? "");
              finishPrompt(prompt, values);
            }}
          >
            <header className="modal-head"><strong>{prompt.title}</strong></header>
            <div className="modal-body">
              {(prompt.fields ?? []).map((f, i) => (
                <label key={f.key} className="prompt-field">
                  <span>{f.label}</span>
                  <input name={f.key} defaultValue={f.defaultValue ?? ""} autoFocus={i === 0} autoComplete="off" />
                </label>
              ))}
              <div className="buttons prompt-actions">
                <button type="button" className="btn" onClick={() => finishPrompt(prompt, null)}>Cancelar</button>
                <button type="submit" className="btn btn-sel">OK</button>
              </div>
            </div>
          </form>
        </div>
      )}

      {modal && (
        <div className="modal-backdrop" onClick={() => setModal(null)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <header className="modal-head">
              <strong>{TITULOS[modal]}</strong>
              <button className="btn btn-icon" onClick={() => setModal(null)}>✕</button>
            </header>
            <div className="modal-body">
              {modal === "fontes" && <SourcesPanel run={run} />}
              {modal === "audio" && <AudioPanel run={run} meters={meters} />}
              {modal === "saidas" && <OutputsPanel run={run} />}
              {modal === "definicoes" && <SettingsPanel run={run} engineUrl={engineUrl} />}
              {modal === "overlays" && <Overlays run={run} />}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
