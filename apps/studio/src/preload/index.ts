// Ponte mínima. A UI trata `window.wtvDesktop` como opcional (ausente em browsers na LAN).
import { contextBridge, ipcRenderer } from "electron";

const api = {
  locateEngine: (): Promise<{ url: string; token: string | null; source: string }> =>
    ipcRenderer.invoke("engine:locate"),
  appVersion: (): Promise<string> => ipcRenderer.invoke("app:version"),
  /** Diálogo nativo de ficheiros (kind: video | image | any). Devolve caminhos absolutos. */
  pickFiles: (kind: "video" | "image" | "any", multiple: boolean): Promise<string[]> =>
    ipcRenderer.invoke("dialog:files", { kind, multiple }),
  /** Diálogo nativo de pasta. */
  pickFolder: (title: string): Promise<string | null> => ipcRenderer.invoke("dialog:folder", { title }),
  /** Abre um painel (audio, definicoes, playout, saidas, fontes, overlays) numa janela própria do sistema. */
  openPanel: (name: string, title: string): Promise<void> => ipcRenderer.invoke("panel:open", { name, title }),
};

contextBridge.exposeInMainWorld("wtvDesktop", api);

export type WtvDesktopApi = typeof api;
