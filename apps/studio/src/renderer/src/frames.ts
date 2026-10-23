// Encaminha o frame multiview descodificado para vários canvases (monitores e miniaturas),
// recortando o tile de cada fonte. Um só descodificador para toda a interface (D13).
import { useEffect, useRef } from "react";
import type { Tile } from "@wtv/protocol";

type Target = { canvas: HTMLCanvasElement; ctx: CanvasRenderingContext2D };

class FrameRouter {
  private targets = new Map<string, Set<Target>>();
  private tiles: Tile[] = [];
  private frameW = 1280;
  private frameH = 720;

  setTiles(tiles: Tile[]): void {
    this.tiles = tiles;
  }

  register(source: string, canvas: HTMLCanvasElement): () => void {
    const ctx = canvas.getContext("2d", { alpha: false });
    if (!ctx) return () => {};
    const t = { canvas, ctx };
    let set = this.targets.get(source);
    if (!set) {
      set = new Set();
      this.targets.set(source, set);
    }
    set.add(t);
    return () => {
      set?.delete(t);
    };
  }

  draw(frame: VideoFrame): void {
    try {
      this.frameW = frame.displayWidth;
      this.frameH = frame.displayHeight;
      for (const tile of this.tiles) {
        const set = this.targets.get(tile.source);
        if (!set || set.size === 0) continue;
        const sx = Math.round(tile.rect.x * this.frameW);
        const sy = Math.round(tile.rect.y * this.frameH);
        const sw = Math.round(tile.rect.w * this.frameW);
        const sh = Math.round(tile.rect.h * this.frameH);
        if (sw <= 0 || sh <= 0) continue;
        for (const t of set) {
          if (t.canvas.width !== sw || t.canvas.height !== sh) {
            t.canvas.width = sw;
            t.canvas.height = sh;
          }
          t.ctx.drawImage(frame, sx, sy, sw, sh, 0, 0, sw, sh);
        }
      }
    } finally {
      frame.close(); // sem isto o descodificador pára ao fim de ~8 frames por fechar
    }
  }

  hasTile(source: string): boolean {
    return this.tiles.some((t) => t.source === source);
  }
}

export const frameRouter = new FrameRouter();

/** Devolve uma ref para um canvas que passa a mostrar o tile da fonte (program, preview ou inputId). */
export function useTileCanvas(source: string | null | undefined) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    if (!ref.current || !source) return;
    return frameRouter.register(source, ref.current);
  }, [source]);
  return ref;
}
