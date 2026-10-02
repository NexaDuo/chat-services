import { test, expect, beforeAll, afterAll } from "vitest";
import Fastify from "fastify";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { registerAdminRoutes } from "./admin.js";

// The SPA build output does not exist under src/, so the static plugin is
// never registered in the other admin tests. This fixture stands in for
// `dist/public/app/assets` to pin what @fastify/static serves and refuses
// (the 8.x line had path-normalisation advisories; W10b moved to 10.x).
const appDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../public/app");
const assetsDir = path.join(appDir, "assets");
const config = {
  chatwoot: { baseUrl: "https://cw.example.com", apiToken: "t", platformToken: "p" },
  evolution: { baseUrl: "https://evo.example.com", apiKey: "" },
  dify: { baseUrl: "https://dify.example.com" },
} as any;
const pool = { query: async () => ({ rows: [], rowCount: 0 }) } as any;

beforeAll(() => {
  fs.mkdirSync(assetsDir, { recursive: true });
  fs.writeFileSync(path.join(assetsDir, "fixture.js"), "export const fixture = 1;\n");
  fs.writeFileSync(path.join(assetsDir, ".hidden.js"), "export const fixture = 1;\n");
  fs.writeFileSync(path.join(appDir, "index.html"), "<!doctype html><title>fixture</title>\n");
});
afterAll(() => {
  fs.rmSync(appDir, { recursive: true, force: true });
});

test("built admin assets are served publicly with a JavaScript content type", async () => {
  const app = Fastify();
  await registerAdminRoutes(app as any, config, pool);
  const res = await app.inject({ method: "GET", url: "/admin/app/assets/fixture.js" });
  expect(res.statusCode).toBe(200);
  expect(res.headers["content-type"]).toMatch(/javascript/);
  expect(res.payload).toContain("fixture = 1");
});

test("the assets prefix never serves files outside the assets directory", async () => {
  const app = Fastify();
  await registerAdminRoutes(app as any, config, pool);
  for (const url of [
    "/admin/app/assets/",
    "/admin/app/assets/../index.html",
    "/admin/app/assets/..%2findex.html",
    "/admin/app/assets/%2e%2e/index.html",
    "/admin/app/assets/..%2f..%2f..%2fpackage.json",
    "/admin/app/assets//fixture.js",
    "/admin/app/assets/fixture.js%00.png",
    "/admin/app/assets/..%5cindex.html",
    "/admin/app/assetsX/fixture.js",
    "/admin/app/assets/.hidden.js",
  ]) {
    const res = await app.inject({ method: "GET", url });
    expect([400, 403, 404], url).toContain(res.statusCode);
    // File contents, not the word in the URL (Fastify's 404 body echoes the URL).
    expect(res.payload, url).not.toContain("fixture = 1");
    expect(res.payload, url).not.toContain("<title>");
  }
});

test("the SPA entry stays behind the session check", async () => {
  const app = Fastify();
  await registerAdminRoutes(app as any, config, pool);
  const res = await app.inject({ method: "GET", url: "/admin/app" });
  expect(res.statusCode).toBe(302);
  expect(res.headers.location).toBe("/admin/login");
});
