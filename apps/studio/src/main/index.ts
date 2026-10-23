// Processo principal do Electron: supervisor do motor e janelas. Nunca toca em media (D1).
// O motor é um bundle .app lançado via LaunchServices (`open`) para ter identidade TCC própria (D2);
// a interface é carregada do próprio motor (mesma origem: cookies e WebCodecs funcionam).
import { app, BrowserWindow, dialog, ipcMain, shell } from "electron";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
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
  return resolve(__dirname, "..", "..", "..", "..", "engine", "dist", "WTV Engine.app");
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
  // Espera até 15 s por engine.json + health
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 250));
    const info = await readEngineInfo();
    if (info && info.pid && (await probe(`http://127.0.0.1:${info.port}`, info.token))) {
      return { url: `http://127.0.0.1:${info.port}`, token: info.token, source: "launched" };
    }
  }
  return { url: `http://127.0.0.1:${DEFAULT_PORT}`, token: null, source: "none" };
}

let mainWindow: BrowserWindow | null = null;

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
