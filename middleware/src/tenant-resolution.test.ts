import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test, expect, vi } from "vitest";
import yaml from "yaml";
import { resolveTenant, resolveTenantDetailed } from "./config.js";
import { assertUniqueActiveAccounts, buildSeedSql, type TenantConfig } from "./tenants-seed.js";

// Regression for issue #292 / #275: tenants.yaml seeded two rows with
// chatwoot_account_id=1 (nexaduo active + acme-dedicated onboarding) and
// resolveTenant picked one non-deterministically.
//
// These tests drive the REAL producer path: the repo's real tenants.yaml ->
// the real seed builder (the same code `scripts/sync-tenants.ts --print-sql`
// pipes into psql) -> an in-memory tenants table fed by executing that SQL ->
// the real resolveTenant with the account id taken from a Chatwoot webhook
// payload. Nothing asserts a hard-coded discriminator on a hand-built row set.

const here = path.dirname(fileURLToPath(import.meta.url));
const tenantsYaml = path.resolve(here, "../../tenants.yaml");

type Row = {
  slug: string;
  chatwoot_account_id: string;
  status: string;
  dify_api_key: string | null;
  dify_app_type: string;
  created_at: number;
};

/**
 * Minimal stand-in for the middleware.tenants table: it "executes" the INSERT
 * statements emitted by buildSeedSql and enforces the same invariant as the
 * partial unique index in infrastructure/postgres/01-init.sql
 * (uq_tenants_active_chatwoot_account). The SELECT mirrors resolveTenant's.
 */
function fakeTenantsDb(seedSql: string, opts: { enforceIndex: boolean }) {
  const rows: Row[] = [];
  let clock = 0;
  for (const stmt of seedSql.split(/;\n(?=INSERT|COMMIT)/)) {
    if (!stmt.startsWith("INSERT INTO tenants")) continue;
    const values = stmt.match(/VALUES \((.*)\)\nON CONFLICT/s)![1];
    const lit = [...values.matchAll(/'((?:[^']|'')*)'|NULL/g)].map((m) =>
      m[1] === undefined ? null : m[1].replace(/''/g, "'"),
    );
    // columns: slug, subdomain, name, account, status, infra_type, chatwoot_url, dify_url, app_type, api_key
    const next: Row = {
      slug: lit[0]!,
      chatwoot_account_id: lit[3]!,
      status: lit[4]!,
      dify_app_type: lit[8]!,
      dify_api_key: lit[9],
      created_at: clock++,
    };
    const idx = rows.findIndex((r) => r.slug === next.slug);
    if (idx >= 0) rows.splice(idx, 1);
    if (
      opts.enforceIndex &&
      next.status === "active" &&
      rows.some((r) => r.status === "active" && r.chatwoot_account_id === next.chatwoot_account_id)
    ) {
      throw new Error(
        'duplicate key value violates unique constraint "uq_tenants_active_chatwoot_account"',
      );
    }
    rows.push(next);
  }
  const pool = {
    // Honours only what the issued SQL actually says: WHERE chatwoot_account_id = $1
    // and, if present, ORDER BY slug. With no ORDER BY the rows come back in
    // insertion order, so the DECISION must be made by resolveTenant itself (the
    // pre-#292 code took rows[0] and fails when the non-active row came first).
    query: vi.fn(async (sql: string, params: string[]) => {
      expect(sql).toMatch(/WHERE\s+chatwoot_account_id\s*=\s*\$1/);
      const out = rows.filter((r) => r.chatwoot_account_id === params[0]);
      if (/ORDER BY\s+slug\s+ASC/i.test(sql)) out.sort((a, b) => a.slug.localeCompare(b.slug));
      return { rows: out };
    }),
  };
  return { rows, pool };
}

const config = { dify: { baseUrl: "https://dify.example.test" } } as any;

/** What the webhook handler does: account id from the payload, as a string. */
function accountFromWebhook(payload: { account: { id: number } }) {
  return String(payload.account.id);
}

function realTenants(): TenantConfig[] {
  const parsed = yaml.parse(fs.readFileSync(tenantsYaml, "utf8")) as { tenants: TenantConfig[] };
  return parsed.tenants.filter((t) => (t.environment || "production") === "production");
}

test("the real tenants.yaml seed has one active tenant per Chatwoot account and resolves each to itself", async () => {
  const tenants = realTenants();
  expect(() => assertUniqueActiveAccounts(tenants)).not.toThrow();

  // Give each tenant a distinct Dify key so a mix-up is observable.
  const withKeys = tenants.map((t) => ({
    ...t,
    infra: { ...t.infra!, dify_api_key: `key-${t.slug}` },
  }));
  const { pool } = fakeTenantsDb(buildSeedSql(withKeys), { enforceIndex: true });

  for (const t of withKeys.filter((x) => x.status === "active")) {
    const resolved = await resolveTenant(
      config,
      accountFromWebhook({ account: { id: t.chatwoot_account_id } }),
      pool as any,
    );
    expect(resolved?.apiKey).toBe(`key-${t.slug}`);
  }
});

test("no two tenants in ANY environment share an active account id (one DB serves them all)", () => {
  const all = (yaml.parse(fs.readFileSync(tenantsYaml, "utf8")) as { tenants: TenantConfig[] }).tenants;
  expect(() => assertUniqueActiveAccounts(all)).not.toThrow();
  expect(all.map((t) => t.slug)).not.toContain("acme-dedicated");
  expect(all.map((t) => t.slug)).not.toContain("acme-stg");
});

test("two tenants sharing an account id cannot both be active (seed builder rejects)", () => {
  const base = realTenants()[0];
  const dup: TenantConfig = { ...base, slug: "second-firm", name: "Second Firm" };
  expect(() => buildSeedSql([base, dup])).toThrow(/chatwoot_account_id \d+ has 2 active tenants/);
  expect(() => assertUniqueActiveAccounts([base, dup])).toThrow(base.slug);
  // A non-active tenant may share the account id (e.g. onboarding).
  expect(() => assertUniqueActiveAccounts([base, { ...dup, status: "onboarding" }])).not.toThrow();
});

test("duplicate slugs are rejected rather than silently collapsed by the upsert", () => {
  const base = realTenants()[0];
  expect(() => assertUniqueActiveAccounts([base, { ...base }])).toThrow(/duplicate slug/);
});

test("unique index semantics: the DB layer also refuses a second active tenant on one account", () => {
  const [a] = realTenants();
  const b: TenantConfig = { ...a, slug: "second-firm" };
  // Bypass the builder's guard to prove the DB-side invariant independently.
  const sqlFor = (t: TenantConfig) => buildSeedSql([t]);
  const combined = sqlFor(a) + sqlFor(b);
  expect(() => fakeTenantsDb(combined, { enforceIndex: true })).toThrow(/uq_tenants_active_chatwoot_account/);
});

test("resolveTenant is deterministic: active wins over a non-active row on the same account", async () => {
  const base = realTenants()[0];
  const onboarding: TenantConfig = {
    ...base,
    slug: "aaa-onboarding",
    status: "onboarding",
    infra: { ...base.infra!, dify_api_key: "key-onboarding" },
  };
  const active: TenantConfig = { ...base, infra: { ...base.infra!, dify_api_key: "key-active" } };
  // Seed order must not matter.
  for (const order of [[onboarding, active], [active, onboarding]]) {
    const { pool } = fakeTenantsDb(buildSeedSql(order), { enforceIndex: true });
    const resolved = await resolveTenant(config, accountFromWebhook({ account: { id: base.chatwoot_account_id } }), pool as any);
    expect(resolved?.apiKey).toBe("key-active");
  }
});

test("resolveTenant refuses to guess when the DB has two active rows (index not applied)", async () => {
  const base = realTenants()[0];
  const a: TenantConfig = { ...base, infra: { ...base.infra!, dify_api_key: "key-a" } };
  const b: TenantConfig = { ...base, slug: "second-firm", infra: { ...base.infra!, dify_api_key: "key-b" } };
  // Seed the two statements separately: the builder guard would (rightly) reject both at once.
  const { pool } = fakeTenantsDb(buildSeedSql([a]) + buildSeedSql([b]), { enforceIndex: false });
  const err = vi.spyOn(console, "error").mockImplementation(() => {});
  try {
    const resolved = await resolveTenant(config, base.chatwoot_account_id, pool as any);
    expect(resolved).toBeNull();
    expect(err).toHaveBeenCalledWith(expect.stringContaining("AMBIGUOUS_TENANT_MAPPING"));
  } finally {
    err.mockRestore();
  }
});

test("status is an off switch: a lone onboarding/suspended row does NOT resolve, with a distinct reason", async () => {
  const base = realTenants()[0];
  const err = vi.spyOn(console, "error").mockImplementation(() => {});
  try {
    for (const status of ["onboarding", "suspended"]) {
      const row: TenantConfig = { ...base, status, infra: { ...base.infra!, dify_api_key: "key-x" } };
      const { pool } = fakeTenantsDb(buildSeedSql([row]), { enforceIndex: true });
      expect(await resolveTenant(config, base.chatwoot_account_id, pool as any)).toBeNull();
      expect(await resolveTenantDetailed(config, base.chatwoot_account_id, pool as any)).toEqual({
        ok: false,
        reason: "tenant_inactive",
      });
    }
    // Two non-active rows: still inactive (the index does not constrain them), never a guess.
    const a: TenantConfig = { ...base, status: "onboarding" };
    const b: TenantConfig = { ...base, slug: "other", status: "onboarding" };
    const { pool } = fakeTenantsDb(buildSeedSql([a, b]), { enforceIndex: true });
    expect((await resolveTenantDetailed(config, base.chatwoot_account_id, pool as any)).ok).toBe(false);
  } finally {
    err.mockRestore();
  }
});

test("resolveTenantDetailed distinguishes no mapping, ambiguity and success", async () => {
  const base = realTenants()[0];
  const a: TenantConfig = { ...base, infra: { ...base.infra!, dify_api_key: "key-a" } };
  const b: TenantConfig = { ...base, slug: "second-firm" };
  const err = vi.spyOn(console, "error").mockImplementation(() => {});
  try {
    const ok = fakeTenantsDb(buildSeedSql([a]), { enforceIndex: true });
    expect(await resolveTenantDetailed(config, base.chatwoot_account_id, ok.pool as any)).toMatchObject({ ok: true });
    expect(await resolveTenantDetailed(config, 999, ok.pool as any)).toEqual({ ok: false, reason: "no_tenant_mapping" });
    const amb = fakeTenantsDb(buildSeedSql([a]) + buildSeedSql([b]), { enforceIndex: false });
    expect(await resolveTenantDetailed(config, base.chatwoot_account_id, amb.pool as any)).toEqual({
      ok: false,
      reason: "tenant_ambiguous",
    });
  } finally {
    err.mockRestore();
  }
});

test("admin flows cannot hit the unique violation by design: parent tenants are the single active row on account 1", () => {
  // REV-4: admin.ts models parent (physical) tenants as `status='active' AND
  // chatwoot_account_id='1'`, and client accounts as account != '1'. Under the
  // index only one parent can be active; client-account inserts use account ids
  // != '1', and POST import pre-checks `subdomain = $1 OR chatwoot_account_id = $2`.
  const admin = fs.readFileSync(path.resolve(here, "handlers/admin.ts"), "utf8");
  expect(admin).toMatch(/subdomain = \$1 OR chatwoot_account_id = \$2 LIMIT 1/);
  expect(admin).toMatch(/chatwoot_account_id != '1'/);
});

test("the unique index is declared idempotently in 01-init.sql", () => {
  const sql = fs.readFileSync(path.resolve(here, "../../infrastructure/postgres/01-init.sql"), "utf8");
  expect(sql).toMatch(
    /CREATE UNIQUE INDEX IF NOT EXISTS uq_tenants_active_chatwoot_account\s+ON tenants\(chatwoot_account_id\) WHERE status = 'active';/,
  );
});
