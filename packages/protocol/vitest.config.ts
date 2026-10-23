import { defineConfig } from "vitest/config";

// O volume exFAT cria ficheiros AppleDouble "._*"; nunca são testes.
export default defineConfig({
  test: {
    include: ["test/**/*.test.ts", "src/**/*.test.ts"],
    exclude: ["**/node_modules/**", "**/._*"],
  },
});
