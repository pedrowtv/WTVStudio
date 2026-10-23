import { useCallback, useEffect, useState } from "react";
import type { MeterReading } from "@wtv/protocol";
import { useStore } from "./store";
import { RpcDomainError, newTxnId } from "./rpc";
import { PreviewClient } from "./preview";
import { frameRouter } from "./frames";
import { Monitor } from "./components/Monitor";
import { TransitionColumn } from "./components/TransitionColumn";
import { InputStrip, InputTabs, useStripTab } from "./components/InputStrip";
import { Overlays } from "./components/Overlays";
import { ReplayPanel } from "./components/ReplayPanel";
import { AudioPanel, OutputsPanel, SettingsPanel, PlayoutPanel, SourcesPanel } from "./components/panels";
import { DOCK_ORDER, DOCK_TITLES, DockArea, dockChannel, useDocks, type DockName } from "./components/Docks";
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

type Modal = null | "fontes" | "audio" | "saidas" | "definicoes" | "overlays" | "playout" | "replay";
/** Relógio de régie (hora local, atualiza a cada segundo). */
function Clock() {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => { const t = setInterval(() => setNow(new Date()), 1000); return () => clearInterval(t); }, []);
  return <span className="clock" title={now.toLocaleDateString("pt-PT")}>{now.toLocaleTimeString("pt-PT")}</span>;
}

const TITULOS: Record<Exclude<Modal, null>, string> = { fontes: "Fontes", audio: "Audio Mixer", saidas: "Saídas", definicoes: "Definições", overlays: "Overlays", playout: "Playout", replay: "Replay" };

/** Caixa de texto própria (o Electron não tem window.prompt). */
function PromptHost({ prompt }: { prompt: NonNullable<ReturnType<typeof usePromptHost>> }) {
  return (
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
  );
}

/** Faixa de erro RPC (clique para fechar); a mesma na janela principal e nas janelas flutuantes (?panel=). */
function ErrorBanner({ erro, onClose }: { erro: string | null; onClose: () => void }) {
  if (!erro) return null;
  return <div className="banner banner-erro" onClick={onClose}>{erro}</div>;
}

/** Abre um painel em janela própria (Electron) ou numa janela do browser (fallback). */
function openPanelWindow(name: Exclude<Modal, null>): void {
  const title = TITULOS[name];
  if (window.wtvDesktop?.openPanel) { void window.wtvDesktop.openPanel(name, title); return; }
  window.open(`${location.origin}${location.pathname}?panel=${name}`, `wtv-${name}`, "width=1000,height=640,title=" + encodeURIComponent(title));
}

export function App({ engineUrl, token, panel }: { engineUrl: string; token: string | null; panel?: string | null }) {
  const connection = useStore((s) => s.connection);
  const engine = useStore((s) => s.engine);
  const client = useStore((s) => s.client);
  const [erro, setErro] = useState<string | null>(null);
  const [modal, setModal] = useState<Modal>(null);
  const [meters, setMeters] = useState<MeterReading[]>([]);
  const [previewStatus, setPreviewStatus] = useState("a ligar…");
  const prompt = usePromptHost();
  const docks = useDocks();
  const [stripTab, setStripTab] = useStripTab();
  const [panelsMenu, setPanelsMenu] = useState(false);

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

  // Atalhos do replay (sem modal/caixa aberta; com a fonte Replay criada ou ângulos armados): R = no ar / voltar ao vivo,
  // ⇧1–⇧9 = capturar lance do ângulo N, [ = 50 %, ] = 100 %.
  const replay = engine?.replay;
  useEffect(() => {
    if (!replay || replay.status === "unavailable" || (!replay.inputId && replay.angles.length === 0)) return;
    const onKey = (e: KeyboardEvent) => {
      // Só os campos de escrita consomem teclas; um botão ou checkbox com foco (depois de um clique no painel) não deve calar o R.
      const t = e.target as HTMLElement | null;
      const typing = t && (t.tagName === "TEXTAREA" || t.tagName === "SELECT" || t.isContentEditable ||
        (t.tagName === "INPUT" && !["checkbox", "radio", "range", "button", "submit"].includes((t as HTMLInputElement).type)));
      if (typing) return;
      if (e.metaKey || e.ctrlKey || e.repeat) return;
      if (document.querySelector(".modal-backdrop")) return;
      // ⇧1–⇧9 captura o lance do ângulo N. Decide-se pelo e.code porque com Shift o e.key nos teclados PT é "!", "\"", …
      // (1–9 sem Shift é a coluna de transição: fonte N para Preview).
      const digit = e.shiftKey && !e.altKey ? /^Digit([1-9])$/.exec(e.code) : null;
      if (digit) {
        const id = replay.angles[Number(digit[1]) - 1];
        if (id) void run("replay.capture", { inputId: id });
        return;
      }
      // Nos teclados portugueses do Mac, [ e ] saem com Alt+8 / Alt+9: o Alt só é bloqueado para o R.
      if (e.key === "[") void run("replay.setSpeed", { percent: 50 });
      else if (e.key === "]") void run("replay.setSpeed", { percent: 100 });
      else if (!e.altKey && e.key.toLowerCase() === "r") {
        // Com o Replay no ar o R volta sempre ao directo (mesmo já sem ângulos); pô-lo no ar exige a fonte Replay.
        if (replay.onAir) void run("replay.backToLive", {});
        else if (replay.inputId) void run("replay.onAir", {});
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [replay, run]);

  // Janela flutuante: anuncia-se à janela principal e avisa quando fecha (reencaixe automático).
  useEffect(() => {
    if (!panel || !dockChannel) return;
    const ch = dockChannel;
    document.title = `WTV Studio — ${TITULOS[panel as Exclude<Modal, null>] ?? panel}`;
    ch.postMessage({ type: "floating", name: panel });
    const bye = () => ch.postMessage({ type: "closed", name: panel });
    window.addEventListener("pagehide", bye);
    return () => window.removeEventListener("pagehide", bye);
  }, [panel]);

  // Modo janela destacada: só o painel pedido, a ocupar toda a janela.
  if (panel) {
    const name = panel as Exclude<Modal, null>;
    return (
      <div className="panel-window">
        {prompt && <PromptHost prompt={prompt} />}
        <header className="panel-window-head"><strong>{TITULOS[name] ?? panel}</strong><span className="spacer" /><span className={`pill pill-${connection}`}>{connection === "connected" ? "motor ligado" : connection === "connecting" ? "a ligar…" : "sem motor"}</span>{name !== "definicoes" && <button className="btn btn-x" title="Voltar a encaixar na janela principal" onClick={() => window.close()}>⇤ Encaixar</button>}</header>
        {erro && <div className="banners"><ErrorBanner erro={erro} onClose={() => setErro(null)} /></div>}
        <div className="panel-window-body">
          {name === "fontes" && <SourcesPanel run={run} />}
          {name === "audio" && <AudioPanel run={run} meters={meters} />}
          {name === "saidas" && <OutputsPanel run={run} />}
          {name === "definicoes" && <SettingsPanel run={run} engineUrl={engineUrl} />}
          {name === "playout" && <PlayoutPanel run={run} />}
          {name === "replay" && <ReplayPanel run={run} />}
          {name === "overlays" && <Overlays run={run} />}
          {!TITULOS[name] && <p className="muted">Painel desconhecido.</p>}
        </div>
      </div>
    );
  }

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
          <span className="brand">WTV STUDIO</span>
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
          <Clock />
          <span className="menu-wrap">
            <button className="btn" onClick={() => setPanelsMenu((v) => !v)}>Painéis ▾</button>
            {panelsMenu && (
              <div className="menu" onMouseLeave={() => setPanelsMenu(false)}>
                {DOCK_ORDER.map((d) => {
                  const st = docks.state.floating.includes(d) ? "janela própria" : docks.state.hidden.includes(d) ? "oculto" : "encaixado";
                  return <button key={d} className="menu-item" onClick={() => { setPanelsMenu(false); if (docks.state.floating.includes(d)) docks.float(d); else docks.show(d); }}><span>{docks.state.hidden.includes(d) ? "○" : "●"}</span>{DOCK_TITLES[d]}<span className="muted small">{st}</span></button>;
                })}
                <div className="menu-sep" />
                {DOCK_ORDER.map((d) => <button key={d + "f"} className="menu-item" onClick={() => { setPanelsMenu(false); docks.float(d); }}><span>⧉</span>{DOCK_TITLES[d]} em janela própria</button>)}
              </div>
            )}
          </span>
          <button className="btn" onClick={() => setModal("definicoes")}>Definições</button>
        </div>
      </header>

      <div className="banners">{/* sempre presente: mantém as linhas da grelha alinhadas */}
        <ErrorBanner erro={erro} onClose={() => setErro(null)} />
        {critical.map((a) => <div key={a.id} className="banner banner-erro">{a.detail ?? a.code}</div>)}
        {connection === "disconnected" && <div className="banner banner-aviso">Sem ligação ao motor. A emissão continua se o motor estiver a correr; a reconectar…</div>}
      </div>

      <main className="stage">
        <Monitor bus="preview" run={run} />
        <TransitionColumn run={run} />
        <Monitor bus="program" run={run} />
      </main>

      <div className="strip-bar">
        <InputTabs tab={stripTab} setTab={setStripTab} />
        <span className="muted small">clique = Preview · duplo clique = Cut · teclas 1–9, Enter, Espaço, F</span>
        <span className="spacer" />
        <button className="btn" onClick={() => docks.show("audio")}>
          🔊 Audio Mixer <span className="mini-meter"><span style={{ width: `${Math.max(0, Math.min(100, ((masterDb + 60) / 60) * 100))}%` }} /></span>
        </button>
      </div>
      <InputStrip run={run} tab={stripTab} />
      <DockArea docks={docks} run={run} meters={meters} />

      <footer className="bottombar">
        <div className="btn-split">
          <button className="btn btn-wide" onClick={() => docks.show("fontes")}>Adicionar fonte</button>
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
          <button className="btn btn-icon" title="Definições de gravação" onClick={() => docks.show("saidas")}>⚙</button>
          <button className={recording ? "btn btn-wide btn-program" : "btn btn-wide"} onClick={() => { if (recording) { if (window.confirm("Parar a gravação?")) void run("record.stop", { txnId: newTxnId() }); } else void run("record.start", { container: "mov", txnId: newTxnId() }); }}>
            {recording ? `● Gravar · ${((engine?.recording.bytes ?? 0) / 1e6).toFixed(0)} MB` : "Gravar"}
          </button>
        </div>
        <div className="btn-split">
          <button className="btn btn-icon" title="Definições de stream" onClick={() => docks.show("saidas")}>⚙</button>
          <button
            className={streaming ? "btn btn-wide btn-program" : "btn btn-wide"}
            onClick={() => {
              const rtmp = outputs.filter((o) => o.kind === "rtmp");
              if (rtmp.length === 0) { docks.show("saidas"); return; }
              if (streaming) { if (window.confirm("Parar o stream?")) rtmp.filter((o) => o.status !== "stopped").forEach((o) => void run("output.stop", { outputId: o.id, txnId: newTxnId() })); }
              else if (window.confirm(`Iniciar o stream para ${rtmp.length} destino(s): ${rtmp.map((o) => o.name).join(", ")}?`)) rtmp.forEach((o) => void run("output.start", { outputId: o.id, txnId: newTxnId() }));
            }}
          >
            {streaming ? "● Stream" : "Stream"}
          </button>
        </div>
        <button className="btn btn-wide" onClick={() => docks.show("saidas")}>Externo (NDI)</button>
        <button className="btn btn-wide" onClick={() => docks.show("overlays")}>Overlay</button>
        <button className="btn btn-wide" onClick={() => docks.show("playout")}>Playout</button>
        <button className={replay?.onAir ? "btn btn-wide btn-program replay-tally" : "btn btn-wide"} title="Replay instantâneo: ângulos, capturar lance, câmara lenta (R, ⇧1–9, [, ])" onClick={() => docks.show("replay")}>{replay?.onAir ? "● REPLAY NO AR" : "Replay"}</button>
        <button className={Object.keys(engine?.recording.iso ?? {}).length ? "btn btn-wide btn-program" : "btn btn-wide"} title="Gravação ISO por fonte" onClick={() => docks.show("saidas")}>{Object.keys(engine?.recording.iso ?? {}).length ? `● ISO ${Object.keys(engine?.recording.iso ?? {}).length}` : "MultiCorder"}</button>
      </footer>
      <footer className="statusbar">
        <span className="status">
          <strong className="status-format">{engine ? `${engine.project.raster.width}×${engine.project.raster.height} ${engine.project.raster.fps}p` : "—"}</strong>
          <span>PGM {engine?.program.inputId ? engine.inputs[engine.program.inputId]?.name : "—"}</span>
          <span>PVW {engine?.preview.inputId ? engine.inputs[engine.preview.inputId]?.name : "—"}</span>
          <span>REC {recording ? `● ${((engine?.recording.bytes ?? 0) / 1e6).toFixed(0)} MB` : "parado"}</span>
          <span>STREAM {liveOutputs > 0 ? `● ${liveOutputs} destino(s)` : "parado"}</span>
          <span>Preview {previewStatus}</span>
          <span>Enc {engine?.budget.encoderUsedPercent.toFixed(0) ?? 0}%</span>
          <span>Térmico {engine?.system.thermal ?? "—"}</span>
          <span className="spacer" />
          <span>{engineUrl}</span>
        </span>
      </footer>

      {prompt && <PromptHost prompt={prompt} />}

      {modal && (
        <div className="modal-backdrop" onClick={() => setModal(null)}>
          <div className={modal === "definicoes" || modal === "playout" || modal === "audio" || modal === "replay" ? "modal modal-wide" : "modal"} onClick={(e) => e.stopPropagation()}>
            <header className="modal-head">
              <strong>{TITULOS[modal]}</strong>
              <span className="spacer" />
              <button className="btn btn-icon" title="Destacar numa janela própria (pode ir para outro ecrã)" onClick={() => { openPanelWindow(modal); setModal(null); }}>⧉ Destacar</button>
              <button className="btn btn-icon" onClick={() => setModal(null)}>✕</button>
            </header>
            <div className="modal-body">
              {modal === "fontes" && <SourcesPanel run={run} />}
              {modal === "audio" && <AudioPanel run={run} meters={meters} />}
              {modal === "saidas" && <OutputsPanel run={run} />}
              {modal === "definicoes" && <SettingsPanel run={run} engineUrl={engineUrl} />}
              {modal === "playout" && <PlayoutPanel run={run} />}
              {modal === "replay" && <ReplayPanel run={run} />}
              {modal === "overlays" && <Overlays run={run} />}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
