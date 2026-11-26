import { defineConfig } from "vitest/config";
import path from "path";

// Unit tests run in jsdom. Kept apart from vite.config.ts so the dev-only
// component tagger plugin is not loaded under test.
export default defineConfig({
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  test: {
    environment: "jsdom",
    setupFiles: ["./src/test/setup.ts"],
    include: ["src/**/*.test.{ts,tsx}"],
  },
});
