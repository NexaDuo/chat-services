import { describe, it, expect } from "vitest";
import { redactUrlSecrets } from "./logger.js";

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

  it("drops the whole query string when it cannot be parsed", () => {
    // URLSearchParams is lenient, so this mainly pins the contract: whatever
    // happens, a query we could not fully inspect must not be logged raw.
    const out = redactUrlSecrets("/x?token=a&%ZZ");
    expect(out).not.toContain("token=a");
  });
});
