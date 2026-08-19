import { describe, it, expect } from "vitest";
import { redactUrlSecrets, __testing } from "./logger.js";

/**
 * Regression tests for the Dify-silent-bot incident (2026-08-19).
 *
 * Chatwoot's generic webhooks cannot send custom headers, so its token
 * arrives as `?token=...`. That makes the raw request URL secret-bearing:
 * during the incident the live token was readable straight out of
 * `docker logs chat-services-middleware-1`. These assertions pin the
 * scrubbing so the token can never reach stdout (and from there Loki) again.
 */
describe("redactUrlSecrets", () => {
  it("redacts the Chatwoot webhook token while keeping the path", () => {
    const out = redactUrlSecrets("/webhooks/chatwoot?token=deadbeefcafe");
    expect(out).toBe("/webhooks/chatwoot?token=%3Credacted%3E");
    expect(out).not.toContain("deadbeefcafe");
  });

  it("redacts every known secret-bearing parameter, case-insensitively", () => {
    const out = redactUrlSecrets(
      "/x?ACCESS_TOKEN=SEKRET1&api_key=SEKRET2&ApiKey=SEKRET3",
    );
    expect(out).not.toContain("SEKRET1");
    expect(out).not.toContain("SEKRET2");
    expect(out).not.toContain("SEKRET3");
  });

  it("keeps non-secret parameters intact", () => {
    const out = redactUrlSecrets("/webhooks/chatwoot?token=secret&page=2");
    expect(out).toContain("page=2");
    expect(out).not.toContain("secret");
  });

  it("leaves URLs without a query string untouched", () => {
    expect(redactUrlSecrets("/health")).toBe("/health");
  });

  it("passes through undefined", () => {
    expect(redactUrlSecrets(undefined)).toBeUndefined();
  });

  it("still redacts when the query has malformed percent-encoding", () => {
    // `URLSearchParams` is lenient and does not throw here, so this asserts the
    // normal path stays correct on ugly input. The `catch` in redactUrlSecrets
    // is defence-in-depth for a future parser change, not a reachable branch
    // today — flagged by @rev on PR #176.
    const out = redactUrlSecrets("/x?token=SEKRET&%ZZ");
    expect(out).not.toContain("SEKRET");
  });
});

/**
 * Regression test for the observability defect @rev caught on PR #176.
 *
 * The custom serializer replaces Fastify's default one. Reading
 * `socket.remoteAddress`/`headers.host` instead of Fastify's `ip`/`host`
 * getters would ignore `trustProxy` (set in index.ts) and log the reverse
 * proxy's address on EVERY request line — the whole stack sits behind
 * coolify-proxy, so that silently blinds every client-IP-based query.
 */
describe("redactingReqSerializer", () => {
  const serialize = __testing.redactingReqSerializer;

  it("uses Fastify's trustProxy-aware ip/host over the raw socket", () => {
    const out = serialize({
      method: "POST",
      url: "/webhooks/chatwoot?token=SEKRET",
      ip: "203.0.113.7", // real client, resolved via X-Forwarded-For
      host: "middleware.nexaduo.com",
      headers: { host: "middleware:4000" },
      socket: { remoteAddress: "172.19.0.23", remotePort: 5555 }, // the proxy
    });
    expect(out.remoteAddress).toBe("203.0.113.7");
    expect(out.host).toBe("middleware.nexaduo.com");
  });

  it("redacts the token from the logged url", () => {
    const out = serialize({ method: "POST", url: "/webhooks/chatwoot?token=SEKRET" });
    expect(String(out.url)).not.toContain("SEKRET");
  });

  it("falls back to socket/headers when the getters are absent", () => {
    const out = serialize({
      method: "GET",
      url: "/health",
      headers: { host: "127.0.0.1:4000" },
      socket: { remoteAddress: "127.0.0.1", remotePort: 42 },
    });
    expect(out.remoteAddress).toBe("127.0.0.1");
    expect(out.host).toBe("127.0.0.1:4000");
  });
});
