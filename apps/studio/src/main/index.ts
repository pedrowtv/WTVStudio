// Processo principal do Electron: supervisor do motor e janelas. Nunca toca em media (D1).
// O motor é um bundle .app lançado via LaunchServices (`open`) para ter identidade TCC própria (D2);
// a interface é carregada do próprio motor (mesma origem: cookies e WebCodecs funcionam).
import { app, BrowserWindow, dialog, ipcMain, shell } from "electron";
import { execFile } from "node:child_process";
import { appendFileSync, existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { homedir } from "node:os";

const DEFAULT_PORT = 7420;

interface EngineInfo {
  pid: number;
  port: number;
  token: string;
  version: string;
  startedAt: string;
}

interface EngineLocation {
  url: string;
  token: string | null;
  source: "engine.json" | "dev" | "launched" | "none";
}

const isPackaged = app.isPackaged;

function dataDir(): string {
  return join(homedir(), "Library", "Application Support", "WTV Studio");
}

/** Caminho do bundle do motor: Contents/Helpers na app empacotada, engine/dist em desenvolvimento. */
function engineBundlePath(): string {
  if (isPackaged) return resolve(process.resourcesPath, "..", "Helpers", "WTV Engine.app");
  const root = resolve(__dirname, "..", "..", "..", "..");
  const obs = resolve(root, "engine-obs", "dist", "WTV Engine.app"); // motor libobs (D23); o Swift fica como alternativa
  return existsSync(obs) ? obs : resolve(root, "engine", "dist", "WTV Engine.app");
}

/** Pasta com a UI construída, servida pelo motor em /. */
function uiPath(): string {
  return resolve(__dirname, "..", "renderer");
}

async function readEngineInfo(): Promise<EngineInfo | null> {
  try {
    return JSON.parse(await readFile(join(dataDir(), "engine.json"), "utf8")) as EngineInfo;
  } catch {
    return null;
  }
}

async function probe(url: string, token?: string | null): Promise<boolean> {
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 1500);
    const res = await fetch(`${url}/api/health`, { signal: ctrl.signal, headers: token ? { Authorization: `Bearer ${token}` } : {} });
    clearTimeout(t);
    return res.ok;
  } catch {
    return false;
  }
}

function openBundle(bundle: string, args: string[]): Promise<void> {
  return new Promise((res, rej) => {
    execFile("/usr/bin/open", ["-g", "-n", "-a", bundle, "--args", ...args], (err) => (err ? rej(err) : res()));
  });
}

let launching: Promise<EngineLocation> | null = null;

/** Encontra um motor em execução ou lança o bundle e espera que escreva engine.json. */
async function locateEngine(): Promise<EngineLocation> {
  const info = await readEngineInfo();
  if (info) {
    const url = `http://127.0.0.1:${info.port}`;
    if (await probe(url, info.token)) return { url, token: info.token, source: "engine.json" };
  }
  const devUrl = `http://127.0.0.1:${DEFAULT_PORT}`;
  if (await probe(devUrl)) return { url: devUrl, token: null, source: "dev" };

  if (!launching) launching = launchEngine().finally(() => (launching = null));
  return launching;
}

async function launchEngine(): Promise<EngineLocation> {
  const bundle = engineBundlePath();
  if (!existsSync(bundle)) {
    return { url: `http://127.0.0.1:${DEFAULT_PORT}`, token: null, source: "none" };
  }
  // Empacotado: o bundle traz a UI em Contents/Resources/ui. Em desenvolvimento passa-se a pasta do build.
  const args = ["--port", String(DEFAULT_PORT)];
  if (!isPackaged) args.push("--ui", uiPath());
  await openBundle(bundle, args);
  // Espera até 60 s por engine.json + health (a libobs demora 10–20 s a carregar módulos e shaders no arranque)
  for (let i = 0; i < 240; i++) {
    await new Promise((r) => setTimeout(r, 250));
    const info = await readEngineInfo();
    if (info && info.pid && (await probe(`http://127.0.0.1:${info.port}`, info.token))) {
      return { url: `http://127.0.0.1:${info.port}`, token: info.token, source: "launched" };
    }
  }
  return { url: `http://127.0.0.1:${DEFAULT_PORT}`, token: null, source: "none" };
}

const PANEL_SIZE: Record<string, [number, number]> = { audio: [1100, 640], definicoes: [1040, 700], playout: [980, 620], saidas: [760, 600], fontes: [760, 560], overlays: [760, 520] };
let mainWindow: BrowserWindow | null = null;
let engineToken: string | null = null;
function logLine(...parts: unknown[]): void {
  const line = `${new Date().toISOString()} ${parts.map(String).join(" ")}\n`;
  console.log(line.trim());
  try { appendFileSync(join(homedir(), "Library", "Logs", "WTV Studio", "studio.log"), line); } catch { /* sem log */ }
}

async function createWindow(): Promise<void> {
  mainWindow = new BrowserWindow({
    width: 1680,
    height: 1000,
    minWidth: 1200,
    minHeight: 760,
    title: "WTV Studio",
    backgroundColor: "#0b0d12",
    show: false,
    webPreferences: {
      preload: join(__dirname, "../preload/index.mjs"),
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
    },
  });
  mainWindow.once("ready-to-show", () => mainWindow?.show());
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    void shell.openExternal(url);
    return { action: "deny" };
  });

  if (process.env.ELECTRON_RENDERER_URL) {
    // Desenvolvimento: UI do servidor Vite; o renderer encontra o motor via locateEngine.
    await mainWindow.loadURL(process.env.ELECTRON_RENDERER_URL);
    return;
  }
  const loc = await locateEngine();
  if (loc.source === "none") {
    await mainWindow.loadFile(join(__dirname, "../renderer/index.html"));
    dialog.showErrorBox("Motor não encontrado", `Não foi possível lançar o motor de vídeo (WTV Engine.app) em:\n${engineBundlePath()}`);
    return;
  }
  // UI servida pelo motor; o token vai na query e é trocado por cookie no renderer.
  const url = new URL(loc.url);
  if (loc.token) url.searchParams.set("token", loc.token);
  engineToken = loc.token;
  // window.open("?panel=…") a partir da UI abre uma janela normal com o mesmo preload (painéis destacáveis).
  mainWindow.webContents.setWindowOpenHandler(({ url: target }) => {
    logLine("[panel] window.open", target);
    const t = new URL(target);
    if (!t.searchParams.get("panel")) { void shell.openExternal(target); return { action: "deny" }; }
    const [width, height] = PANEL_SIZE[t.searchParams.get("panel") ?? ""] ?? [800, 600];
    return { action: "allow", overrideBrowserWindowOptions: { width, height, minWidth: 480, minHeight: 360, backgroundColor: "#121315", webPreferences: { preload: join(__dirname, "../preload/index.mjs"), contextIsolation: true, sandbox: false } } };
  });
  mainWindow.webContents.on("did-create-window", (w) => { w.setMenuBarVisibility(false); logLine("[panel] janela criada", w.getTitle()); });
  logLine("[main] a carregar", url.origin + url.pathname, "preload", join(__dirname, "../preload/index.mjs"));
  await mainWindow.loadURL(url.toString());
}

ipcMain.handle("engine:locate", async () => locateEngine());

const FILTERS: Record<string, Electron.FileFilter[]> = {
  video: [
    { name: "Vídeo e áudio", extensions: ["mp4", "mov", "m4v", "mkv", "mxf", "avi", "webm", "mp3", "m4a", "wav", "aac", "aiff", "flac"] },
    { name: "Todos os ficheiros", extensions: ["*"] },
  ],
  image: [
    { name: "Imagens", extensions: ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp", "bmp"] },
    { name: "Todos os ficheiros", extensions: ["*"] },
  ],
  any: [{ name: "Todos os ficheiros", extensions: ["*"] }],
};

ipcMain.handle("dialog:files", async (_e, { kind, multiple }: { kind: string; multiple: boolean }) => {
  const r = await dialog.showOpenDialog(mainWindow ?? undefined!, {
    title: kind === "image" ? "Escolher imagem" : "Escolher ficheiro",
    properties: multiple ? ["openFile", "multiSelections"] : ["openFile"],
    filters: FILTERS[kind] ?? FILTERS.any,
  });
  return r.canceled ? [] : r.filePaths;
});

ipcMain.handle("dialog:folder", async (_e, { title }: { title: string }) => {
  const r = await dialog.showOpenDialog(mainWindow ?? undefined!, { title, properties: ["openDirectory", "createDirectory"] });
  return r.canceled || r.filePaths.length === 0 ? null : r.filePaths[0];
});
ipcMain.handle("app:version", () => app.getVersion());

/** Painéis destacáveis: a mesma UI com ?panel=nome numa BrowserWindow normal (move-se para qualquer ecrã). */
const panelWindows = new Map<string, BrowserWindow>();
ipcMain.handle("panel:open", async (e, { name, title }: { name: string; title: string }) => {
  logLine("[panel] abrir", name, "de", e.sender.getURL());
  const existing = panelWindows.get(name);
  if (existing && !existing.isDestroyed()) { existing.show(); existing.focus(); return; }
  const [width, height] = PANEL_SIZE[name] ?? [800, 600];
  const parentUrl = new URL(e.sender.getURL());
  const win = new BrowserWindow({
    width, height, minWidth: 480, minHeight: 360, title: `WTV Studio — ${title}`, backgroundColor: "#121315",
    webPreferences: { preload: join(__dirname, "../preload/index.mjs"), contextIsolation: true, sandbox: false },
  });
  panelWindows.set(name, win);
  win.on("closed", () => { logLine("[panel] fechado", name); panelWindows.delete(name); });
  win.webContents.on("render-process-gone", (_ev, d) => logLine("[panel] renderer caiu", name, d.reason));
  win.setMenuBarVisibility(false);
  const url = new URL(parentUrl.origin + parentUrl.pathname);
  url.searchParams.set("panel", name);
  if (engineToken) url.searchParams.set("token", engineToken); // a janela nova troca o token por cookie como a principal
  try { await win.loadURL(url.toString()); logLine("[panel] carregado", url.origin + url.pathname + "?panel=" + name); }
  catch (err) { logLine("[panel] erro", String(err)); }
});

app.whenReady().then(async () => {
  await createWindow();
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) void createWindow();
  });
});

// Fechar a janela nunca pára o motor (D20): o motor é um processo independente lançado pelo launchd.
app.on("window-all-closed", () => {
  app.quit();
});
