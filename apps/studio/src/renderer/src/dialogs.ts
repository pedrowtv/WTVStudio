// Diálogos da interface. No Electron, window.prompt() não existe; usamos diálogos nativos (ficheiros,
// pastas) pelo processo principal e uma caixa de texto própria em React (PromptHost) para texto.
import { useEffect, useState } from "react";

export type FileKind = "video" | "image" | "any";

interface DesktopDialogs {
  pickFiles?: (kind: FileKind, multiple: boolean) => Promise<string[]>;
  pickFolder?: (title: string) => Promise<string | null>;
}

function desktop(): DesktopDialogs | undefined {
  return (window as unknown as { wtvDesktop?: DesktopDialogs }).wtvDesktop;
}

/** Escolhe ficheiros. Na app usa o diálogo nativo; num browser pede o caminho por texto. */
export async function pickFiles(kind: FileKind, multiple = true): Promise<string[]> {
  const d = desktop();
  if (d?.pickFiles) return d.pickFiles(kind, multiple);
  const path = await askText(kind === "image" ? "Caminho da imagem" : "Caminho do ficheiro", "Caminho completo no Mac onde corre o motor:");
  return path ? [path] : [];
}

export async function pickFolder(title: string): Promise<string | null> {
  const d = desktop();
  if (d?.pickFolder) return d.pickFolder(title);
  return askText(title, "Caminho da pasta no Mac onde corre o motor:");
}

// ---- Caixa de texto em React -------------------------------------------

export interface TextPrompt {
  title: string;
  label: string;
  defaultValue?: string;
  fields?: { key: string; label: string; defaultValue?: string }[];
  resolve: (value: Record<string, string> | null) => void;
}

let setPending: ((p: TextPrompt | null) => void) | null = null;

/** Uma pergunta de texto simples. Devolve null se o utilizador cancelar. */
export function askText(title: string, label: string, defaultValue = ""): Promise<string | null> {
  return askFields(title, [{ key: "value", label, defaultValue }]).then((r) => (r ? r.value : null));
}

/** Várias perguntas de texto numa só caixa. */
export function askFields(title: string, fields: { key: string; label: string; defaultValue?: string }[]): Promise<Record<string, string> | null> {
  return new Promise((resolve) => {
    if (!setPending) {
      resolve(null);
      return;
    }
    setPending({ title, label: "", fields, resolve });
  });
}

/** Componente a montar uma vez na App: desenha a caixa quando há uma pergunta pendente. */
export function usePromptHost(): TextPrompt | null {
  const [pending, set] = useState<TextPrompt | null>(null);
  useEffect(() => {
    setPending = set;
    return () => {
      setPending = null;
    };
  }, []);
  return pending;
}

export function finishPrompt(p: TextPrompt, values: Record<string, string> | null): void {
  p.resolve(values);
  setPending?.(null);
}
