import { test, expect, vi } from "vitest";
import Fastify from "fastify";
import { registerAdminRoutes } from "./admin.js";

// Minimal config — the accounts/dify endpoints only use `pool` + cookie auth.
const config = {
  chatwoot: { baseUrl: "https://cw.example.com", apiToken: "t", platformToken: "p" },
  evolution: { baseUrl: "https://evo.example.com", apiKey: "" },
  dify: { baseUrl: "https://dify.example.com" },
} as any;

const SESSION_ROW = { id: "s1", username: "admin", role: "admin" };

// Builds a pool whose query() branches on the SQL text. `authed` controls
// whether the session lookup returns a row.
function makePool(opts: {
  authed?: boolean;
  accounts?: any[];
  updateRowCount?: number;
}) {
  const { authed = true, accounts = [], updateRowCount = 1 } = opts;
  return {
    query: vi.fn(async (sql: string) => {
      if (/FROM sessions/.test(sql)) return { rows: authed ? [SESSION_ROW] : [] };
      if (/FROM tenants/.test(sql)) return { rows: accounts };
      if (/UPDATE tenants/.test(sql)) return { rowCount: updateRowCount, rows: [] };
      return { rows: [] };
    }),
  };
}

const AUTH = { cookie: "admin_session=tok" };

test("GET /admin/api/accounts exposes difyApiKeySet boolean, never the key", async () => {
  const app = Fastify();
  const pool = makePool({
    accounts: [
      { slug: "duda", subdomain: "duda", name: "Maria Eduarda", chatwoot_account_id: "3", status: "active", dify_app_type: "agent", chatwoot_url: "https://chat.nexaduo.com", dify_url: "https://dify.nexaduo.com", dify_api_key: "app-duda-secret" },
      { slug: "nexaduo", subdomain: "nexaduo", name: "NexaDuo", chatwoot_account_id: "1", status: "active", dify_app_type: "chatflow", chatwoot_url: "https://chat.nexaduo.com", dify_url: null, dify_api_key: null },
    ],
  });
  await registerAdminRoutes(app as any, config, pool as any);

  const res = await app.inject({ method: "GET", url: "/admin/api/accounts", headers: AUTH });
  expect(res.statusCode).toBe(200);
  const body = JSON.parse(res.payload);
  expect(body[0]).toMatchObject({ slug: "duda", difyAppType: "agent", difyApiKeySet: true, chatwootUrl: "https://chat.nexaduo.com", difyUrl: "https://dify.nexaduo.com" });
  expect(body[1]).toMatchObject({ slug: "nexaduo", difyApiKeySet: false });
  // The raw key/column must never leak to the client.
  expect(res.payload).not.toContain("dify_api_key");
  expect(res.payload).not.toContain("app-duda-secret");
});

test("GET /admin/api/accounts requires a valid session", async () => {
  const app = Fastify();
  await registerAdminRoutes(app as any, config, makePool({ authed: false }) as any);
  const res = await app.inject({ method: "GET", url: "/admin/api/accounts", headers: AUTH });
  expect(res.statusCode).toBe(401);
});

test("PUT /admin/api/accounts/:slug/dify rejects an invalid app type", async () => {
  const app = Fastify();
  await registerAdminRoutes(app as any, config, makePool({}) as any);
  const res = await app.inject({
    method: "PUT",
    url: "/admin/api/accounts/duda/dify",
    headers: AUTH,
    payload: { difyAppType: "bogus" },
  });
  expect(res.statusCode).toBe(400);
  expect(JSON.parse(res.payload).error).toBe("invalid_dify_app_type");
});

test("PUT updates dify config and never echoes the key", async () => {
  const app = Fastify();
  const pool = makePool({});
  await registerAdminRoutes(app as any, config, pool as any);
  const res = await app.inject({
    method: "PUT",
    url: "/admin/api/accounts/duda/dify",
    headers: AUTH,
    payload: { difyAppType: "agent", difyApiKey: "app-supersecret" },
  });
  expect(res.statusCode).toBe(200);
  const body = JSON.parse(res.payload);
  expect(body).toMatchObject({ status: "success", slug: "duda", difyAppType: "agent", difyApiKeyUpdated: true });
  expect(res.payload).not.toContain("app-supersecret");
  // The UPDATE must have been issued.
  expect(pool.query.mock.calls.some(([sql]) => /UPDATE tenants/.test(sql as string))).toBe(true);
});

test("PUT returns 404 for an unknown slug", async () => {
  const app = Fastify();
  await registerAdminRoutes(app as any, config, makePool({ updateRowCount: 0 }) as any);
  const res = await app.inject({
    method: "PUT",
    url: "/admin/api/accounts/ghost/dify",
    headers: AUTH,
    payload: { difyAppType: "chatflow" },
  });
  expect(res.statusCode).toBe(404);
});
