import { describe, it, expect, afterEach } from "vitest";
import net from "node:net";
import pg from "pg";
import { loadConfig, buildPoolOptions } from "./config.js";
import { resolveTenantWithRetry } from "./handlers/chatwoot-webhook.js";

// Issue #299: the pool must fail fast against a hung Postgres so the #298
// fallback path (tenant_lookup_failed -> infra reply) runs inside Chatwoot's
// 5 s webhook timeout.
const base = {
  CHATWOOT_BASE_URL: "https://chat.example",
  DIFY_BASE_URL: "https://dify.example",
  HANDOFF_SHARED_SECRET: "x".repeat(16),
  DATABASE_URL: "postgres://u:p@localhost:5432/db",
};

describe("loadConfig pg timeouts (#299)", () => {
  it("defaults keep 3 attempts inside the 5 s webhook budget", () => {
    const c = loadConfig({ ...base });
    expect(c.db.connectionTimeoutMs).toBe(1000);
    expect(c.db.queryTimeoutMs).toBe(1200);
    expect(3 * c.db.queryTimeoutMs + 300).toBeLessThan(5000);
    const o = buildPoolOptions(c);
    expect(o.connectionTimeoutMillis).toBe(1000);
    expect(o.query_timeout).toBe(1200);
    expect(o.statement_timeout).toBe(2500);
    expect(o.idleTimeoutMillis).toBe(10000);
  });
  it("empty string => default; value => override; invalid => throws", () => {
    expect(loadConfig({ ...base, PG_QUERY_TIMEOUT_MS: "" }).db.queryTimeoutMs).toBe(1200);
    expect(loadConfig({ ...base, PG_QUERY_TIMEOUT_MS: "900" }).db.queryTimeoutMs).toBe(900);
    expect(() => loadConfig({ ...base, PG_QUERY_TIMEOUT_MS: "-1" })).toThrow();
  });
});

describe("pool against a hung Postgres (#299)", () => {
  let server: net.Server | undefined;
  let pool: pg.Pool | undefined;
  afterEach(async () => {
    await pool?.end().catch(() => {});
    server?.close();
    server = undefined;
    pool = undefined;
  });

  function listen(onConn: (s: net.Socket) => void): Promise<number> {
    return new Promise((resolve) => {
      server = net.createServer(onConn).listen(0, "127.0.0.1", () => {
        resolve((server!.address() as net.AddressInfo).port);
      });
    });
  }
  const cfgFor = (port: number) =>
    loadConfig({
      ...base,
      DATABASE_URL: `postgres://u:p@127.0.0.1:${port}/db`,
      PG_CONNECTION_TIMEOUT_MS: "300",
      PG_QUERY_TIMEOUT_MS: "300",
    });

  it("connect to a server that never answers startup errors within the timeout", async () => {
    const port = await listen(() => {}); // accept, say nothing
    pool = new pg.Pool(buildPoolOptions(cfgFor(port)));
    pool.on("error", () => {});
    const t0 = Date.now();
    await expect(pool.query("select 1")).rejects.toThrow(/timeout/i);
    expect(Date.now() - t0).toBeLessThan(1500);
  });

  it("a query that never returns errors within query_timeout", async () => {
    // Minimal wire protocol: AuthenticationOk + ReadyForQuery, then ignore queries.
    const port = await listen((s) => {
      s.on("error", () => {});
      s.once("data", () => {
        s.write(Buffer.from([0x52, 0, 0, 0, 8, 0, 0, 0, 0, 0x5a, 0, 0, 0, 5, 0x49]));
      });
    });
    pool = new pg.Pool(buildPoolOptions(cfgFor(port)));
    pool.on("error", () => {});
    const t0 = Date.now();
    await expect(pool.query("select 1")).rejects.toThrow(/timeout/i);
    expect(Date.now() - t0).toBeLessThan(1500);
  });

  it("tenant lookup: slow connect + hung query is bounded by the OVERALL deadline (REV-2)", async () => {
    // Startup answered after 250 ms, then queries hang: each attempt ~250+300 ms,
    // so 3 attempts + backoff (~1.9 s) would blow past a 900 ms overall deadline.
    const port = await listen((s) => {
      s.on("error", () => {});
      s.once("data", () => {
        setTimeout(() => {
          s.write(Buffer.from([0x52, 0, 0, 0, 8, 0, 0, 0, 0, 0x5a, 0, 0, 0, 5, 0x49]));
        }, 250);
      });
    });
    const config = loadConfig({
      ...base,
      DATABASE_URL: `postgres://u:p@127.0.0.1:${port}/db`,
      PG_CONNECTION_TIMEOUT_MS: "600",
      PG_QUERY_TIMEOUT_MS: "300",
      PG_RESOLVE_DEADLINE_MS: "900",
    });
    pool = new pg.Pool(buildPoolOptions(config));
    pool.on("error", () => {});
    const log = { warn: () => {} } as any;
    const t0 = Date.now();
    const res = await resolveTenantWithRetry(config, "42", pool, log, { accountId: "42", conversationId: 1 });
    const dt = Date.now() - t0;
    expect(res).toEqual({ ok: false, reason: "tenant_lookup_failed" });
    expect(dt).toBeLessThan(1300);
  });
});

describe("pg timeout env validation (REV-7)", () => {
  it.each([
    ["PG_QUERY_TIMEOUT_MS", "0"],
    ["PG_QUERY_TIMEOUT_MS", "-5"],
    ["PG_CONNECTION_TIMEOUT_MS", "abc"],
    ["PG_STATEMENT_TIMEOUT_MS", "99999999999"],
    ["PG_RESOLVE_DEADLINE_MS", "60001"],
  ])("%s=%s fails boot naming the variable", (name, value) => {
    expect(() => loadConfig({ ...base, [name]: value })).toThrow(new RegExp(name));
  });
  it("PG_RESOLVE_DEADLINE_MS defaults to 4000", () => {
    expect(loadConfig({ ...base }).db.resolveDeadlineMs).toBe(4000);
  });
});
