import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { RpcClient } from "./rpc";
import { bindClient } from "./store";
import { DEFAULT_PORT } from "@wtv/protocol";

declare global {
  interface Window {
    wtvDesktop?: {
      locateEngine: () => Promise<{ url: string; token: string | null; source: string }>;
      appVersion: () => Promise<string>;
    };
  }
}

async function boot(): Promise<void> {
  let url = `http://127.0.0.1:${DEFAULT_PORT}`;
  let token: string | null = null;
  const kind: "electron" | "browser" = window.wtvDesktop ? "electron" : "browser";

  if (location.protocol.startsWith("http") && !location.port.startsWith("517")) {
    // Servido pelo próprio motor (app empacotada ou browser na LAN): mesma origem.
    url = location.origin;
    token = new URLSearchParams(location.search).get("token");
    if (token) {
      // Troca o token por cookie HttpOnly e tira-o do URL visível.
      try {
        await fetch("/api/session", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ token }), credentials: "same-origin" });
        history.replaceState(null, "", location.pathname);
      } catch {
        /* sem cookie: continua com o token na query dos WebSockets */
      }
    }
  } else if (window.wtvDesktop) {
    // Desenvolvimento no Electron (UI do Vite): pergunta ao processo principal onde está o motor.
    const loc = await window.wtvDesktop.locateEngine();
    url = loc.url;
    token = loc.token;
  }

  const client = new RpcClient(url, token, kind);
  bindClient(client);
  client.connect();

  createRoot(document.getElementById("root")!).render(
    <React.StrictMode>
      <App engineUrl={url} token={token} />
    </React.StrictMode>,
  );
}

void boot();
