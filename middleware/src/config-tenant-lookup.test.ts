import { describe, it, expect, vi } from "vitest";
import { resolveTenantDetailed } from "./config.js";

// Issue #293 (REV-1): a pool/query error must be distinguishable from a
// genuine "no row", otherwise a transient outage is a silent no_tenant_mapping.
const config = { dify: { baseUrl: "https://dify.example" } } as any;

describe("resolveTenantDetailed error vs not-found (#293)", () => {
  it("query throws => tenant_lookup_failed (not no_tenant_mapping)", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const pool = { query: vi.fn().mockRejectedValue(new Error("ECONNRESET")) } as any;
    expect(await resolveTenantDetailed(config, 42, pool)).toEqual({ ok: false, reason: "tenant_lookup_failed" });
  });
  it("no rows => no_tenant_mapping", async () => {
    const pool = { query: vi.fn().mockResolvedValue({ rows: [] }) } as any;
    expect(await resolveTenantDetailed(config, 42, pool)).toEqual({ ok: false, reason: "no_tenant_mapping" });
  });
});
