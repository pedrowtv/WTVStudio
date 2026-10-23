import { defineConfig, externalizeDepsPlugin } from "electron-vite";
import react from "@vitejs/plugin-react";
import { resolve } from "node:path";

export default defineConfig({
  main: {
    plugins: [externalizeDepsPlugin()],
    build: { outDir: "out/main" },
  },
  preload: {
    plugins: [externalizeDepsPlugin()],
    build: { outDir: "out/preload" },
  },
  renderer: {
    plugins: [react()],
    resolve: {
      alias: {
        "@wtv/protocol": resolve(__dirname, "../../packages/protocol/src/index.ts"),
      },
    },
    build: { outDir: "out/renderer" },
  },
});
