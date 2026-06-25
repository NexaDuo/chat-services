import { defineConfig } from "vitest/config";

// Separate from vite.config.ts (which sets root: admin-ui for the React build).
// Tests are backend TS under src/; keep the project root here so vitest finds
// them and does not inherit the SPA build root.
export default defineConfig({
  test: {
    root: ".",
    include: ["src/**/*.test.ts"],
    environment: "node",
  },
});
