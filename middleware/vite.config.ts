import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "path";
import { fileURLToPath } from "url";

const dir = path.dirname(fileURLToPath(import.meta.url));

// The admin React SPA lives in `admin-ui/` (outside `src/`, so the backend
// `tsc` build never compiles it). It builds to `dist/public/app`, which the
// Fastify server serves under `/admin/app/` (see registerAdminRoutes). `base`
// must match that prefix so emitted asset URLs resolve correctly.
export default defineConfig({
  plugins: [react()],
  root: path.resolve(dir, "admin-ui"),
  base: "/admin/app/",
  build: {
    outDir: path.resolve(dir, "dist/public/app"),
    emptyOutDir: true,
  },
});
