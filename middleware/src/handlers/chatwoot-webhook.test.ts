import { describe, it, expect } from "vitest";
import { extractWebhookToken, safeTokenEqual } from "./chatwoot-webhook.js";

/**
 * Regression tests for the silent-bot incident (2026-08-19, PR #176).
 *
 * The middleware read the webhook token ONLY from the header, but Chatwoot's
 * generic webhooks cannot set custom headers — it sends `?token=...`. Every
 * `message_created` therefore got a 401 and Dify was never invoked, with no
 * alert anywhere. These assertions pin the accepted channels so the bot
 * cannot go mute that way again.
 */
describe("extractWebhookToken", () => {
  it("accepts the token from the query string — the only channel Chatwoot has", () => {
    expect(extractWebhookToken(undefined, "abc")).toEqual({
      token: "abc",
      source: "query",
    });
  });

  it("accepts the token from the header", () => {
    expect(extractWebhookToken("abc", undefined)).toEqual({
      token: "abc",
      source: "header",
    });
  });

  it("prefers the header when both are present", () => {
    expect(extractWebhookToken("from-header", "from-query")).toEqual({
      token: "from-header",
      source: "header",
    });
  });

  it("does NOT fall back to the query when the header is present but wrong", () => {
    // Falling back would let a caller who controls only one channel pick
    // whichever one they can forge.
    const { token } = extractWebhookToken("wrong", "right");
    expect(token).toBe("wrong");
  });

  it("rejects a repeated query parameter but still reports it as query", () => {
    // `?token=a&token=b` parses to an array: ambiguous, so no token — but the
    // source must stay diagnosable in the 401 log line.
    expect(extractWebhookToken(undefined, ["a", "b"])).toEqual({ source: "query" });
  });

  it("rejects a repeated header but still reports it as header", () => {
    expect(extractWebhookToken(["a", "b"], "c")).toEqual({ source: "header" });
  });

  it("reports none when neither channel carries a token", () => {
    expect(extractWebhookToken(undefined, undefined)).toEqual({ source: "none" });
  });
});

describe("safeTokenEqual", () => {
  it("accepts an exact match", () => {
    expect(safeTokenEqual("s3cret", "s3cret")).toBe(true);
  });

  it("rejects a different value of the same length", () => {
    expect(safeTokenEqual("aaaaaa", "bbbbbb")).toBe(false);
  });

  it("rejects a matching prefix of different length without throwing", () => {
    // timingSafeEqual throws on length mismatch — the length guard must run first.
    expect(() => safeTokenEqual("s3cr", "s3cret")).not.toThrow();
    expect(safeTokenEqual("s3cr", "s3cret")).toBe(false);
  });

  it("rejects the empty string against a real token", () => {
    expect(safeTokenEqual("", "s3cret")).toBe(false);
  });
});
