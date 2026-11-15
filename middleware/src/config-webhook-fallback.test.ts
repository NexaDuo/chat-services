import { describe, it, expect } from "vitest";
import { loadConfig, DEFAULT_EMPTY_CONTENT_REPLY, DEFAULT_INFRA_FALLBACK_REPLY } from "./config.js";

// Issue #293: compose passes `${WEBHOOK_*_REPLY:-}`, so an UNSET host variable
// reaches the container as "". That must mean "use the default", not crash
// the min(1) validation and not disable the fallback.
const base = {
  CHATWOOT_BASE_URL: "https://chat.example",
  DIFY_BASE_URL: "https://dify.example",
  HANDOFF_SHARED_SECRET: "x".repeat(16),
  DATABASE_URL: "postgres://u:p@localhost:5432/db",
};

describe("loadConfig webhook fallback replies (#293)", () => {
  it("unset => defaults", () => {
    const c = loadConfig({ ...base });
    expect(c.webhook.emptyContentReply).toBe(DEFAULT_EMPTY_CONTENT_REPLY);
    expect(c.webhook.infraFallbackReply).toBe(DEFAULT_INFRA_FALLBACK_REPLY);
  });
  it("empty / whitespace string => defaults (does not throw)", () => {
    const c = loadConfig({ ...base, WEBHOOK_EMPTY_CONTENT_REPLY: "", WEBHOOK_INFRA_FALLBACK_REPLY: "  " });
    expect(c.webhook.emptyContentReply).toBe(DEFAULT_EMPTY_CONTENT_REPLY);
    expect(c.webhook.infraFallbackReply).toBe(DEFAULT_INFRA_FALLBACK_REPLY);
  });
  it("set => used verbatim", () => {
    const c = loadConfig({ ...base, WEBHOOK_EMPTY_CONTENT_REPLY: "A", WEBHOOK_INFRA_FALLBACK_REPLY: "B" });
    expect(c.webhook.emptyContentReply).toBe("A");
    expect(c.webhook.infraFallbackReply).toBe("B");
  });
});
