import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import Fastify from "fastify";
import {
  extractWebhookToken,
  safeTokenEqual,
  registerChatwootWebhookRoute,
} from "./chatwoot-webhook.js";
import { createMetrics } from "../metrics.js";
import type { AppConfig } from "../config.js";

const { chatBlocking, chatStreaming } = vi.hoisted(() => ({
  chatBlocking: vi.fn(),
  chatStreaming: vi.fn(),
}));

vi.mock("../dify.js", () => ({
  DifyClient: vi.fn().mockImplementation(function FakeDifyClient() {
    return { chatBlocking, chatStreaming };
  }),
}));

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

/**
 * Real Chatwoot `message_created` payload shape, per
 * https://www.chatwoot.com/docs/product/channels/api/receive-messages —
 * NOT a hand-picked minimal fixture. Per issue #179's regression-test spec:
 * a fixture that only sets the discriminant fields we happen to read today
 * can stay green while Chatwoot's real payload shape drifts.
 */
function chatwootMessageCreated(params: {
  id: number;
  content: string;
  accountId: number;
  conversationId: number;
  difyConversationId?: string;
}) {
  return {
    id: params.id,
    content: params.content,
    created_at: new Date().toISOString(),
    message_type: "incoming",
    content_type: null,
    content_attributes: {},
    source_id: null,
    private: false,
    sender: { id: 501, name: "Alexandre Machado", avatar: "", type: "contact" },
    inbox: { id: 7, name: "miau.duda" },
    conversation: {
      additional_attributes: null,
      channel: "Channel::Instagram",
      id: params.conversationId,
      inbox_id: 7,
      status: "open",
      agent_last_seen_at: 0,
      contact_last_seen_at: 0,
      timestamp: Math.floor(Date.now() / 1000),
      custom_attributes: params.difyConversationId
        ? { dify_conversation_id: params.difyConversationId }
        : {},
      contact_inbox: { contact_id: 501 },
    },
    account: { id: params.accountId, name: "NexaDuo" },
    event: "message_created",
  };
}

describe("registerChatwootWebhookRoute — burst dedup + watermark (issue #179)", () => {
  function buildFakePool() {
    const tenants = new Map<string, { dify_api_key: string; dify_app_type: string }>();
    const watermarks = new Map<string, number>();
    tenants.set("42", { dify_api_key: "test-dify-key", dify_app_type: "chatflow" });

    const query = vi.fn(async (sql: string, params: unknown[]) => {
      if (sql.includes("FROM tenants")) {
        const row = tenants.get(String(params[0]));
        return { rows: row ? [row] : [] };
      }
      if (sql.includes("SELECT last_processed_message_id")) {
        const key = `${params[0]}:${params[1]}`;
        const value = watermarks.get(key);
        return { rows: value === undefined ? [] : [{ last_processed_message_id: value }] };
      }
      if (sql.includes("INSERT INTO conversation_watermarks")) {
        const key = `${params[0]}:${params[1]}`;
        const incoming = Number(params[2]);
        const current = watermarks.get(key) ?? 0;
        watermarks.set(key, Math.max(current, incoming));
        return { rows: [] };
      }
      throw new Error(`unexpected query in test: ${sql}`);
    });

    return { query, watermarks };
  }

  function buildFakeChatwoot() {
    return {
      postMessage: vi.fn().mockResolvedValue({ id: 1, content: "", private: false, message_type: "outgoing", created_at: "" }),
      setConversationCustomAttributes: vi.fn().mockResolvedValue({}),
    };
  }

  async function buildApp(pool: ReturnType<typeof buildFakePool>, chatwoot: ReturnType<typeof buildFakeChatwoot>) {
    const app = Fastify({ logger: false });
    const config = {
      chatwoot: { webhookToken: undefined, baseUrl: "https://chat.example", apiToken: "x" },
      dify: { baseUrl: "https://dify.example", requestTimeoutMs: 5000 },
      webhook: { debounceMs: 50 },
    } as unknown as AppConfig;
    const metrics = createMetrics();
    await registerChatwootWebhookRoute(app, config, metrics, chatwoot as any, pool as any);
    await app.ready();
    return app;
  }

  beforeEach(() => {
    chatBlocking.mockReset();
    chatStreaming.mockReset();
    chatBlocking.mockResolvedValue({
      message_id: "m1",
      conversation_id: "dify-conv-1",
      answer: "resposta única",
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("two incoming messages in the same conversation within the debounce window produce ONE Dify call and ONE outgoing reply", async () => {
    // Regression for the exact incident in issue #179: msgs 83/84 on
    // conversations.id=8, ~1.5s apart, produced two parallel Dify calls and
    // two outgoing replies. Grouped, they must produce exactly one of each.
    const pool = buildFakePool();
    const chatwoot = buildFakeChatwoot();
    const app = await buildApp(pool, chatwoot);

    await app.inject({
      method: "POST",
      url: "/webhooks/chatwoot",
      payload: chatwootMessageCreated({ id: 83, content: "Shared post", accountId: 42, conversationId: 8 }),
    });
    await app.inject({
      method: "POST",
      url: "/webhooks/chatwoot",
      payload: chatwootMessageCreated({
        id: 84,
        content: "que linda vc está nesta foto ❤️",
        accountId: 42,
        conversationId: 8,
      }),
    });

    // Wait past the 50ms debounce window for the grouped flush to run.
    await new Promise((resolve) => setTimeout(resolve, 200));

    expect(chatBlocking).toHaveBeenCalledTimes(1);
    expect(chatBlocking.mock.calls[0][0].query).toBe(
      "Shared post\nque linda vc está nesta foto ❤️",
    );
    expect(chatwoot.postMessage).toHaveBeenCalledTimes(1);
    expect(chatwoot.postMessage).toHaveBeenCalledWith(
      expect.objectContaining({ messageType: "outgoing", content: "resposta única" }),
    );

    await app.close();
  });

  it("persists the watermark only after a successful post, and skips a group already below it", async () => {
    const pool = buildFakePool();
    const chatwoot = buildFakeChatwoot();
    const app = await buildApp(pool, chatwoot);

    await app.inject({
      method: "POST",
      url: "/webhooks/chatwoot",
      payload: chatwootMessageCreated({ id: 90, content: "oi", accountId: 42, conversationId: 9 }),
    });
    await new Promise((resolve) => setTimeout(resolve, 200));

    expect(pool.watermarks.get("42:9")).toBe(90);
    expect(chatBlocking).toHaveBeenCalledTimes(1);

    // A duplicate/re-delivered webhook for the SAME message id must not
    // trigger a second Dify call or a second reply.
    await app.inject({
      method: "POST",
      url: "/webhooks/chatwoot",
      payload: chatwootMessageCreated({ id: 90, content: "oi", accountId: 42, conversationId: 9 }),
    });
    await new Promise((resolve) => setTimeout(resolve, 200));

    expect(chatBlocking).toHaveBeenCalledTimes(1);
    expect(chatwoot.postMessage).toHaveBeenCalledTimes(1);

    await app.close();
  });

  it("does NOT advance the watermark when the Dify call fails", async () => {
    const pool = buildFakePool();
    const chatwoot = buildFakeChatwoot();
    const app = await buildApp(pool, chatwoot);
    chatBlocking.mockRejectedValueOnce(new Error("dify down"));

    await app.inject({
      method: "POST",
      url: "/webhooks/chatwoot",
      payload: chatwootMessageCreated({ id: 100, content: "oi", accountId: 42, conversationId: 10 }),
    });
    await new Promise((resolve) => setTimeout(resolve, 200));

    expect(pool.watermarks.get("42:10")).toBeUndefined();
    // Best-effort private note attempted despite the failure.
    expect(chatwoot.postMessage).toHaveBeenCalledWith(
      expect.objectContaining({ private: true }),
    );

    await app.close();
  });

  it("does NOT advance the watermark when Dify succeeds but posting the reply to Chatwoot fails", async () => {
    // Gap flagged by @rev on PR #180: the previous test only exercised a
    // Dify failure. The AC says "falha ao postar não avança o watermark" —
    // that is specifically chatwoot.postMessage() for the outgoing reply
    // failing AFTER a successful Dify call, which is a different code path
    // through the same try/catch. This pins that path explicitly.
    const pool = buildFakePool();
    const chatwoot = buildFakeChatwoot();
    // The first postMessage call is the outgoing reply — make it fail.
    // The private-note retry (best-effort) that follows is allowed to succeed.
    chatwoot.postMessage
      .mockRejectedValueOnce(new Error("chatwoot unreachable"))
      .mockResolvedValueOnce({ id: 2, content: "", private: true, message_type: "outgoing", created_at: "" });
    const app = await buildApp(pool, chatwoot);

    await app.inject({
      method: "POST",
      url: "/webhooks/chatwoot",
      payload: chatwootMessageCreated({ id: 110, content: "oi", accountId: 42, conversationId: 11 }),
    });
    await new Promise((resolve) => setTimeout(resolve, 200));

    // Dify WAS called successfully — this is the fragile path: reply-post
    // failure, not Dify failure.
    expect(chatBlocking).toHaveBeenCalledTimes(1);
    // The watermark must NOT have advanced: a redelivery of message 110
    // must still be answered, not silently treated as "already handled".
    expect(pool.watermarks.get("42:11")).toBeUndefined();
    // First call was the (failed) outgoing reply, second was the private note.
    expect(chatwoot.postMessage).toHaveBeenCalledTimes(2);
    expect(chatwoot.postMessage.mock.calls[0][0]).toEqual(
      expect.objectContaining({ messageType: "outgoing", content: "resposta única" }),
    );
    expect(chatwoot.postMessage.mock.calls[1][0]).toEqual(
      expect.objectContaining({ private: true }),
    );

    await app.close();
  });

  it("two different conversations in a simultaneous burst are each answered once, independently", async () => {
    const pool = buildFakePool();
    const chatwoot = buildFakeChatwoot();
    const app = await buildApp(pool, chatwoot);

    await Promise.all([
      app.inject({
        method: "POST",
        url: "/webhooks/chatwoot",
        payload: chatwootMessageCreated({ id: 200, content: "conv A", accountId: 42, conversationId: 20 }),
      }),
      app.inject({
        method: "POST",
        url: "/webhooks/chatwoot",
        payload: chatwootMessageCreated({ id: 201, content: "conv B", accountId: 42, conversationId: 21 }),
      }),
    ]);
    await new Promise((resolve) => setTimeout(resolve, 200));

    expect(chatBlocking).toHaveBeenCalledTimes(2);
    expect(chatwoot.postMessage).toHaveBeenCalledTimes(2);
    expect(pool.watermarks.get("42:20")).toBe(200);
    expect(pool.watermarks.get("42:21")).toBe(201);

    await app.close();
  });
});
