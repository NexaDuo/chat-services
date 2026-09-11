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
  /** Defaults to 501. Pass `null` to omit `contact_inbox` entirely (the
   * real-world case that makes the handler fall back to the "unknown"
   * sentinel contact — issue #204's ARMADILHA). */
  contactId?: number | null;
}) {
  const contactId = params.contactId === undefined ? 501 : params.contactId;
  return {
    id: params.id,
    content: params.content,
    created_at: new Date().toISOString(),
    message_type: "incoming",
    content_type: null,
    content_attributes: {},
    source_id: null,
    private: false,
    sender: { id: contactId ?? 501, name: "Alexandre Machado", avatar: "", type: "contact" },
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
      ...(contactId === null ? {} : { contact_inbox: { contact_id: contactId } }),
    },
    account: { id: params.accountId, name: "NexaDuo" },
    event: "message_created",
  };
}

/**
 * Real payload captured from Chatwoot message 174 (production DB, account 3
 * / tenant `duda`, conversation 16, contact Gabriela Andretta, 2026-09-10),
 * transcribed verbatim from issue #203 with only the Meta `signature=...`
 * query-string values redacted (they are per-request signed URLs, not
 * secrets that identify anything reusable, but AGENTS.md's rule is never to
 * print them regardless). This is the exact case that used to go silent:
 * `content` is empty, but `content_attributes`/`attachments` prove it was a
 * real story reply.
 */
const REAL_MSG_174_STORY_REPLY_PAYLOAD = {
  id: 174,
  content: "",
  content_type: 0,
  created_at: new Date().toISOString(),
  message_type: "incoming",
  content_attributes: {
    story_id: "18099013352357043",
    story_sender: "17841429474434917",
    story_url:
      "https://lookaside.fbsbx.com/ig_messaging_cdn/?asset_id=example&signature=REDACTED",
    image_type: "ig_story_reply",
    in_reply_to_external_id: null,
  },
  attachments: [
    {
      file_type: 11,
      external_url:
        "https://lookaside.fbsbx.com/ig_messaging_cdn/?asset_id=example&signature=REDACTED",
    },
  ],
  source_id: null,
  private: false,
  sender: { id: 9001, name: "Gabriela Andretta", avatar: "", type: "contact" },
  inbox: { id: 7, name: "miau.duda" },
  conversation: {
    additional_attributes: null,
    channel: "Channel::Instagram",
    id: 16,
    inbox_id: 7,
    status: "open",
    agent_last_seen_at: 0,
    contact_last_seen_at: 0,
    timestamp: Math.floor(Date.now() / 1000),
    custom_attributes: {},
    contact_inbox: { contact_id: 9001 },
  },
  account: { id: 42, name: "NexaDuo" },
  event: "message_created",
};

describe("registerChatwootWebhookRoute — burst dedup + watermark (issue #179)", () => {
  function buildFakePool() {
    const tenants = new Map<string, { dify_api_key: string; dify_app_type: string }>();
    const watermarks = new Map<string, number>();
    // configs table (issue #184): undefined key => no row => fail-safe "off".
    // A string here mimics the real `value TEXT` column; `null` mimics a row
    // whose value is a genuine SQL NULL. Set `configsError` to make the read
    // throw, exercising the fail-safe DB-error path.
    const configs = new Map<string, string | null>();
    // contact_dify_conversations (issue #204): key is "accountId:contactId".
    // Exposed on the returned object so tests can assert on it directly.
    const contactDifyConversations = new Map<string, string>();
    let configsError: Error | null = null;
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
      if (sql.includes("FROM contact_dify_conversations")) {
        // Never see a query for the shared "unknown" sentinel — pinned by a
        // dedicated test below via `pool.query` call assertions.
        const key = `${params[0]}:${params[1]}`;
        const value = contactDifyConversations.get(key);
        return { rows: value === undefined ? [] : [{ dify_conversation_id: value }] };
      }
      if (sql.includes("INSERT INTO contact_dify_conversations")) {
        const key = `${params[0]}:${params[1]}`;
        contactDifyConversations.set(key, String(params[2]));
        return { rows: [] };
      }
      if (sql.includes("FROM configs")) {
        if (configsError) throw configsError;
        const key = String(params[0]);
        if (!configs.has(key)) return { rows: [] };
        return { rows: [{ value: configs.get(key) }] };
      }
      throw new Error(`unexpected query in test: ${sql}`);
    });

    return {
      query,
      watermarks,
      configs,
      contactDifyConversations,
      setConfigsError: (err: Error | null) => {
        configsError = err;
      },
    };
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

  /**
   * Regression tests for issue #184: the manual DIFY_KILL_SWITCH. Checked in
   * `flushGroup`, immediately before the Dify call — NOT at enqueue time —
   * specifically so an already-buffered burst (the PR #180 debounce) cannot
   * fire after the operator has turned the switch on. Fail-safe: anything
   * other than the exact string "true" must leave the bot answering.
   */
  describe("DIFY_KILL_SWITCH (issue #184)", () => {
    it("ON ('true') — the flush skips Dify entirely and posts no reply, but the message stays in Chatwoot (it was never dropped, it was never bought there in the first place — Chatwoot persisted it before this webhook fired)", async () => {
      const pool = buildFakePool();
      pool.configs.set("DIFY_KILL_SWITCH", "true");
      const chatwoot = buildFakeChatwoot();
      const app = await buildApp(pool, chatwoot);

      await app.inject({
        method: "POST",
        url: "/webhooks/chatwoot",
        payload: chatwootMessageCreated({ id: 300, content: "oi", accountId: 42, conversationId: 30 }),
      });
      await new Promise((resolve) => setTimeout(resolve, 200));

      expect(chatBlocking).not.toHaveBeenCalled();
      expect(chatwoot.postMessage).not.toHaveBeenCalled();
      // Watermark must not advance either — nothing was "handled".
      expect(pool.watermarks.get("42:30")).toBeUndefined();

      await app.close();
    });

    it("ON with mixed case / surrounding whitespace ('  TRUE ') still counts as ON", async () => {
      const pool = buildFakePool();
      pool.configs.set("DIFY_KILL_SWITCH", "  TRUE ");
      const chatwoot = buildFakeChatwoot();
      const app = await buildApp(pool, chatwoot);

      await app.inject({
        method: "POST",
        url: "/webhooks/chatwoot",
        payload: chatwootMessageCreated({ id: 301, content: "oi", accountId: 42, conversationId: 31 }),
      });
      await new Promise((resolve) => setTimeout(resolve, 200));

      expect(chatBlocking).not.toHaveBeenCalled();
      await app.close();
    });

    it("absent key — bot answers normally (default-off, fresh bootstrap behavior)", async () => {
      const pool = buildFakePool(); // no DIFY_KILL_SWITCH row at all
      const chatwoot = buildFakeChatwoot();
      const app = await buildApp(pool, chatwoot);

      await app.inject({
        method: "POST",
        url: "/webhooks/chatwoot",
        payload: chatwootMessageCreated({ id: 302, content: "oi", accountId: 42, conversationId: 32 }),
      });
      await new Promise((resolve) => setTimeout(resolve, 200));

      expect(chatBlocking).toHaveBeenCalledTimes(1);
      expect(chatwoot.postMessage).toHaveBeenCalledTimes(1);
      await app.close();
    });

    it("empty-string value — bot answers normally", async () => {
      const pool = buildFakePool();
      pool.configs.set("DIFY_KILL_SWITCH", "");
      const chatwoot = buildFakeChatwoot();
      const app = await buildApp(pool, chatwoot);

      await app.inject({
        method: "POST",
        url: "/webhooks/chatwoot",
        payload: chatwootMessageCreated({ id: 303, content: "oi", accountId: 42, conversationId: 33 }),
      });
      await new Promise((resolve) => setTimeout(resolve, 200));

      expect(chatBlocking).toHaveBeenCalledTimes(1);
      await app.close();
    });

    it("SQL NULL value — bot answers normally", async () => {
      const pool = buildFakePool();
      pool.configs.set("DIFY_KILL_SWITCH", null);
      const chatwoot = buildFakeChatwoot();
      const app = await buildApp(pool, chatwoot);

      await app.inject({
        method: "POST",
        url: "/webhooks/chatwoot",
        payload: chatwootMessageCreated({ id: 304, content: "oi", accountId: 42, conversationId: 34 }),
      });
      await new Promise((resolve) => setTimeout(resolve, 200));

      expect(chatBlocking).toHaveBeenCalledTimes(1);
      await app.close();
    });

    it("invalid/garbage value ('maybe') — bot answers normally, does NOT interpret it as ON", async () => {
      const pool = buildFakePool();
      pool.configs.set("DIFY_KILL_SWITCH", "maybe");
      const chatwoot = buildFakeChatwoot();
      const app = await buildApp(pool, chatwoot);

      await app.inject({
        method: "POST",
        url: "/webhooks/chatwoot",
        payload: chatwootMessageCreated({ id: 305, content: "oi", accountId: 42, conversationId: 35 }),
      });
      await new Promise((resolve) => setTimeout(resolve, 200));

      expect(chatBlocking).toHaveBeenCalledTimes(1);
      await app.close();
    });

    it("DB error reading the flag — fail-safe: bot answers normally, error is not fatal to the flush", async () => {
      const pool = buildFakePool();
      pool.setConfigsError(new Error("connection terminated"));
      const chatwoot = buildFakeChatwoot();
      const app = await buildApp(pool, chatwoot);

      await app.inject({
        method: "POST",
        url: "/webhooks/chatwoot",
        payload: chatwootMessageCreated({ id: 306, content: "oi", accountId: 42, conversationId: 36 }),
      });
      await new Promise((resolve) => setTimeout(resolve, 200));

      expect(chatBlocking).toHaveBeenCalledTimes(1);
      expect(chatwoot.postMessage).toHaveBeenCalledTimes(1);
      await app.close();
    });

    it("turning the switch OFF again lets the bot resume answering on the next flush — the two-way check", async () => {
      const pool = buildFakePool();
      pool.configs.set("DIFY_KILL_SWITCH", "true");
      const chatwoot = buildFakeChatwoot();
      const app = await buildApp(pool, chatwoot);

      await app.inject({
        method: "POST",
        url: "/webhooks/chatwoot",
        payload: chatwootMessageCreated({ id: 310, content: "primeira", accountId: 42, conversationId: 40 }),
      });
      await new Promise((resolve) => setTimeout(resolve, 200));
      expect(chatBlocking).not.toHaveBeenCalled();

      // Operator flips it off — no restart, just the config row changing,
      // exactly as it would via the real POST /config or psql.
      pool.configs.set("DIFY_KILL_SWITCH", "false");

      await app.inject({
        method: "POST",
        url: "/webhooks/chatwoot",
        payload: chatwootMessageCreated({ id: 311, content: "segunda", accountId: 42, conversationId: 40 }),
      });
      await new Promise((resolve) => setTimeout(resolve, 200));

      expect(chatBlocking).toHaveBeenCalledTimes(1);
      expect(chatBlocking.mock.calls[0][0].query).toBe("segunda");
      expect(chatwoot.postMessage).toHaveBeenCalledTimes(1);

      await app.close();
    });
  });

  /**
   * Regression tests for issue #204: agent memory moves from per-Chatwoot-
   * conversation to per-CONTACT. Production evidence: contact 4 on account 3
   * had 5 separate Dify conversations (30 messages) instead of one
   * continuous history, because `dify_conversation_id` used to live only in
   * the conversation's `custom_attributes`.
   */
  describe("per-contact Dify memory (issue #204)", () => {
    it("two DIFFERENT Chatwoot conversations of the SAME contact reuse the same Dify conversation_id", async () => {
      const pool = buildFakePool();
      const chatwoot = buildFakeChatwoot();
      const app = await buildApp(pool, chatwoot);

      // First Chatwoot conversation for contact 501 — Dify starts a new
      // conversation and the middleware persists it.
      chatBlocking.mockResolvedValueOnce({
        message_id: "m1",
        conversation_id: "dify-conv-contact-501",
        answer: "primeira resposta",
      });
      await app.inject({
        method: "POST",
        url: "/webhooks/chatwoot",
        payload: chatwootMessageCreated({
          id: 900,
          content: "oi",
          accountId: 42,
          conversationId: 90,
          contactId: 501,
        }),
      });
      await new Promise((resolve) => setTimeout(resolve, 200));

      expect(pool.contactDifyConversations.get("42:501")).toBe("dify-conv-contact-501");

      // Second, DIFFERENT Chatwoot conversation (id=91), same contact
      // (501), no `dify_conversation_id` hint in ITS custom_attributes —
      // exactly the production scenario in the issue. Must reuse the
      // conversation_id from the table, not start a fresh Dify thread.
      await app.inject({
        method: "POST",
        url: "/webhooks/chatwoot",
        payload: chatwootMessageCreated({
          id: 910,
          content: "voltei",
          accountId: 42,
          conversationId: 91,
          contactId: 501,
        }),
      });
      await new Promise((resolve) => setTimeout(resolve, 200));

      expect(chatBlocking).toHaveBeenCalledTimes(2);
      expect(chatBlocking.mock.calls[1][0].conversationId).toBe("dify-conv-contact-501");

      await app.close();
    });

    it("DIFFERENT contacts never share a Dify conversation, even in the same account", async () => {
      const pool = buildFakePool();
      const chatwoot = buildFakeChatwoot();
      const app = await buildApp(pool, chatwoot);

      chatBlocking.mockResolvedValueOnce({
        message_id: "m1",
        conversation_id: "dify-conv-contact-A",
        answer: "resposta A",
      });
      await app.inject({
        method: "POST",
        url: "/webhooks/chatwoot",
        payload: chatwootMessageCreated({
          id: 920,
          content: "oi, sou A",
          accountId: 42,
          conversationId: 92,
          contactId: 601,
        }),
      });
      await new Promise((resolve) => setTimeout(resolve, 200));

      chatBlocking.mockResolvedValueOnce({
        message_id: "m2",
        conversation_id: "dify-conv-contact-B",
        answer: "resposta B",
      });
      await app.inject({
        method: "POST",
        url: "/webhooks/chatwoot",
        payload: chatwootMessageCreated({
          id: 930,
          content: "oi, sou B",
          accountId: 42,
          conversationId: 93,
          contactId: 602,
        }),
      });
      await new Promise((resolve) => setTimeout(resolve, 200));

      expect(pool.contactDifyConversations.get("42:601")).toBe("dify-conv-contact-A");
      expect(pool.contactDifyConversations.get("42:602")).toBe("dify-conv-contact-B");
      // Neither call carried the other contact's conversation_id.
      expect(chatBlocking.mock.calls[0][0].conversationId).toBeUndefined();
      expect(chatBlocking.mock.calls[1][0].conversationId).toBeUndefined();

      await app.close();
    });

    it("ARMADILHA: contactId === \"unknown\" (missing contact_inbox) NEVER reads or writes the shared row, and keeps the old per-conversation behavior", async () => {
      const pool = buildFakePool();
      const chatwoot = buildFakeChatwoot();
      const app = await buildApp(pool, chatwoot);

      chatBlocking.mockResolvedValueOnce({
        message_id: "m1",
        conversation_id: "dify-conv-unknown-1",
        answer: "resposta 1",
      });
      // No `contact_inbox` at all in the payload — the handler falls back to
      // the "unknown" sentinel.
      await app.inject({
        method: "POST",
        url: "/webhooks/chatwoot",
        payload: chatwootMessageCreated({
          id: 940,
          content: "oi",
          accountId: 42,
          conversationId: 94,
          contactId: null,
        }),
      });
      await new Promise((resolve) => setTimeout(resolve, 200));

      // The shared "unknown" row must never exist in the table.
      expect(pool.contactDifyConversations.has("42:unknown")).toBe(false);
      // Nor must any query ever have been issued for it.
      for (const call of pool.query.mock.calls) {
        const [sql, params] = call as [string, unknown[]];
        if (sql.includes("contact_dify_conversations")) {
          expect(params[1]).not.toBe("unknown");
        }
      }

      // A SECOND, unrelated conversation that also lacks contact_inbox must
      // NOT reuse conversation 94's Dify thread — the old per-conversation
      // behavior stays in force for "unknown", so this is a brand-new Dify
      // conversation, not "dify-conv-unknown-1".
      chatBlocking.mockResolvedValueOnce({
        message_id: "m2",
        conversation_id: "dify-conv-unknown-2",
        answer: "resposta 2",
      });
      await app.inject({
        method: "POST",
        url: "/webhooks/chatwoot",
        payload: chatwootMessageCreated({
          id: 950,
          content: "outra pessoa sem contact_id",
          accountId: 42,
          conversationId: 95,
          contactId: null,
        }),
      });
      await new Promise((resolve) => setTimeout(resolve, 200));

      expect(chatBlocking).toHaveBeenCalledTimes(2);
      expect(chatBlocking.mock.calls[1][0].conversationId).toBeUndefined();

      // A THIRD message back in conversation 94 (same conversation as the
      // first) must still reuse ITS OWN Dify conversation_id — the old
      // per-conversation memory is preserved for "unknown" contacts.
      await app.inject({
        method: "POST",
        url: "/webhooks/chatwoot",
        payload: chatwootMessageCreated({
          id: 941,
          content: "voltei na mesma conversa",
          accountId: 42,
          conversationId: 94,
          contactId: null,
        }),
      });
      await new Promise((resolve) => setTimeout(resolve, 200));

      expect(chatBlocking).toHaveBeenCalledTimes(3);
      expect(chatBlocking.mock.calls[2][0].conversationId).toBe("dify-conv-unknown-1");

      await app.close();
    });

    it("falls back to the custom_attributes hint when the table has no row yet (transition compatibility)", async () => {
      const pool = buildFakePool();
      const chatwoot = buildFakeChatwoot();
      const app = await buildApp(pool, chatwoot);

      // Table is empty for this contact, but the webhook carries the OLD
      // per-conversation `dify_conversation_id` custom attribute — as would
      // happen right after this feature ships, before the backfill runs.
      await app.inject({
        method: "POST",
        url: "/webhooks/chatwoot",
        payload: chatwootMessageCreated({
          id: 960,
          content: "oi",
          accountId: 42,
          conversationId: 96,
          contactId: 701,
          difyConversationId: "dify-conv-legacy-hint",
        }),
      });
      await new Promise((resolve) => setTimeout(resolve, 200));

      expect(chatBlocking.mock.calls[0][0].conversationId).toBe("dify-conv-legacy-hint");

      await app.close();
    });

    it("the table takes priority over the custom_attributes hint once it has a row", async () => {
      const pool = buildFakePool();
      pool.contactDifyConversations.set("42:801", "dify-conv-from-table");
      const chatwoot = buildFakeChatwoot();
      const app = await buildApp(pool, chatwoot);

      // Stale hint from an old/different conversation's custom_attributes —
      // the table must win.
      await app.inject({
        method: "POST",
        url: "/webhooks/chatwoot",
        payload: chatwootMessageCreated({
          id: 970,
          content: "oi",
          accountId: 42,
          conversationId: 97,
          contactId: 801,
          difyConversationId: "dify-conv-stale-hint",
        }),
      });
      await new Promise((resolve) => setTimeout(resolve, 200));

      expect(chatBlocking.mock.calls[0][0].conversationId).toBe("dify-conv-from-table");

      await app.close();
    });
  });
});

/**
 * Regression tests for issue #203: an empty `content` used to be silently
 * dropped even when the payload proved there WAS real content (a story
 * reply, an unrecognized attachment) — 4 of 66 incoming messages on account
 * 3, including a real story reply from a real contact that never got a
 * response. These pin: the marker path, the genuinely-empty skip path, the
 * new metric, and the `@sec` requirement that a Meta-signed URL never
 * reaches a log line.
 */
describe("registerChatwootWebhookRoute — empty content marker (issue #203)", () => {
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
      if (sql.includes("FROM contact_dify_conversations")) {
        return { rows: [] };
      }
      if (sql.includes("INSERT INTO contact_dify_conversations")) {
        return { rows: [] };
      }
      if (sql.includes("FROM configs")) {
        return { rows: [] };
      }
      throw new Error(`unexpected query in test: ${sql}`);
    });

    return { query, watermarks };
  }

  function buildFakeChatwoot() {
    return {
      postMessage: vi.fn().mockResolvedValue({
        id: 1,
        content: "",
        private: false,
        message_type: "outgoing",
        created_at: "",
      }),
      setConversationCustomAttributes: vi.fn().mockResolvedValue({}),
    };
  }

  async function buildApp(
    pool: ReturnType<typeof buildFakePool>,
    chatwoot: ReturnType<typeof buildFakeChatwoot>,
    opts?: { logStream?: { write: (chunk: string) => boolean } },
  ) {
    const app = Fastify(
      opts?.logStream
        ? { logger: { level: "info", stream: opts.logStream as any } }
        : { logger: false },
    );
    const config = {
      chatwoot: { webhookToken: undefined, baseUrl: "https://chat.example", apiToken: "x" },
      dify: { baseUrl: "https://dify.example", requestTimeoutMs: 5000 },
      webhook: { debounceMs: 20 },
    } as unknown as AppConfig;
    const metrics = createMetrics();
    await registerChatwootWebhookRoute(app, config, metrics, chatwoot as any, pool as any);
    await app.ready();
    return { app, metrics };
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

  it("story reply (real payload, msg 174) with empty content ⇒ answered with the story-reply marker, not skipped", async () => {
    const pool = buildFakePool();
    const chatwoot = buildFakeChatwoot();
    const { app } = await buildApp(pool, chatwoot);

    const res = await app.inject({
      method: "POST",
      url: "/webhooks/chatwoot",
      payload: REAL_MSG_174_STORY_REPLY_PAYLOAD,
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ ok: true, buffered: true });

    await new Promise((resolve) => setTimeout(resolve, 100));

    expect(chatBlocking).toHaveBeenCalledTimes(1);
    expect(chatBlocking.mock.calls[0][0].query).toBe(
      "[o usuário respondeu ao seu story]",
    );
    // The Dify request must never carry the signed story/attachment URL.
    const serializedDifyCall = JSON.stringify(chatBlocking.mock.calls[0][0]);
    expect(serializedDifyCall).not.toContain("signature=");
    expect(serializedDifyCall).not.toContain("lookaside.fbsbx.com");

    // Duda's answer, not the raw marker, is what reaches the user.
    expect(chatwoot.postMessage).toHaveBeenCalledWith(
      expect.objectContaining({ content: "resposta única" }),
    );

    await app.close();
  });

  it("attachment of an unconfirmed file_type ⇒ generic marker, not skipped", async () => {
    const pool = buildFakePool();
    const chatwoot = buildFakeChatwoot();
    const { app } = await buildApp(pool, chatwoot);

    await app.inject({
      method: "POST",
      url: "/webhooks/chatwoot",
      payload: {
        id: 500,
        content: "",
        content_type: 0,
        message_type: "incoming",
        content_attributes: {},
        attachments: [{ file_type: 999, external_url: "https://example.com/x" }],
        private: false,
        sender: { id: 1, type: "contact" },
        conversation: { id: 50, custom_attributes: {}, contact_inbox: { contact_id: 1 } },
        account: { id: 42 },
        event: "message_created",
      },
    });
    await new Promise((resolve) => setTimeout(resolve, 100));

    expect(chatBlocking).toHaveBeenCalledTimes(1);
    expect(chatBlocking.mock.calls[0][0].query).toBe("[o usuário enviou uma mídia]");

    await app.close();
  });

  it("genuinely empty content (no attachments, no content_attributes signal) ⇒ still skipped, no Dify call", async () => {
    const pool = buildFakePool();
    const chatwoot = buildFakeChatwoot();
    const { app } = await buildApp(pool, chatwoot);

    const res = await app.inject({
      method: "POST",
      url: "/webhooks/chatwoot",
      payload: {
        id: 501,
        content: "",
        content_type: 0,
        message_type: "incoming",
        content_attributes: {},
        private: false,
        sender: { id: 1, type: "contact" },
        conversation: { id: 51, custom_attributes: {}, contact_inbox: { contact_id: 1 } },
        account: { id: 42 },
        event: "message_created",
      },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ skipped: "empty_content" });

    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(chatBlocking).not.toHaveBeenCalled();
    expect(chatwoot.postMessage).not.toHaveBeenCalled();

    await app.close();
  });

  it("counts the marker metric per account/type/outcome, distinguishing answered-with-marker from skipped", async () => {
    const pool = buildFakePool();
    const chatwoot = buildFakeChatwoot();
    const { app, metrics } = await buildApp(pool, chatwoot);

    await app.inject({
      method: "POST",
      url: "/webhooks/chatwoot",
      payload: REAL_MSG_174_STORY_REPLY_PAYLOAD,
    });
    await app.inject({
      method: "POST",
      url: "/webhooks/chatwoot",
      payload: {
        id: 502,
        content: "",
        content_type: 0,
        message_type: "incoming",
        content_attributes: {},
        private: false,
        sender: { id: 1, type: "contact" },
        conversation: { id: 52, custom_attributes: {}, contact_inbox: { contact_id: 1 } },
        account: { id: 42 },
        event: "message_created",
      },
    });
    await new Promise((resolve) => setTimeout(resolve, 100));

    const markerCount = await metrics.emptyContentTotal.get();
    const answered = markerCount.values.find(
      (v) =>
        v.labels.outcome === "answered_with_marker" &&
        v.labels.type === "story_reply" &&
        v.labels.account_id === "42",
    );
    const skipped = markerCount.values.find(
      (v) =>
        v.labels.outcome === "skipped" &&
        v.labels.type === "none" &&
        v.labels.account_id === "42",
    );
    expect(answered?.value).toBe(1);
    expect(skipped?.value).toBe(1);

    await app.close();
  });

  it("never logs the Meta-signed story_url/external_url — `@sec` requirement", async () => {
    const pool = buildFakePool();
    const chatwoot = buildFakeChatwoot();
    const chunks: string[] = [];
    const logStream = {
      write: (chunk: string) => {
        chunks.push(chunk);
        return true;
      },
    };
    const { app } = await buildApp(pool, chatwoot, { logStream });

    await app.inject({
      method: "POST",
      url: "/webhooks/chatwoot",
      payload: REAL_MSG_174_STORY_REPLY_PAYLOAD,
    });
    await new Promise((resolve) => setTimeout(resolve, 100));

    const logOutput = chunks.join("");
    expect(logOutput).not.toContain("signature=");
    expect(logOutput).not.toContain("lookaside.fbsbx.com");
    expect(logOutput).not.toContain("story_url");
    expect(logOutput).not.toContain("external_url");

    await app.close();
  });

  /**
   * `@rev` finding on PR #206 (MEDIUM): a bare `content_attributes.story_id`
   * must NOT by itself be labeled "story reply" — only the OBSERVED
   * `image_type === "ig_story_reply"` may. An unconfirmed story signal
   * (present `story_id`, different/absent `image_type`, no matching
   * attachment) must fall to the generic marker, never a guessed label.
   */
  it("story_id present but image_type is NOT the confirmed reply value ⇒ generic marker, not story_reply", async () => {
    const pool = buildFakePool();
    const chatwoot = buildFakeChatwoot();
    const { app } = await buildApp(pool, chatwoot);

    await app.inject({
      method: "POST",
      url: "/webhooks/chatwoot",
      payload: {
        id: 503,
        content: "",
        content_type: 0,
        message_type: "incoming",
        content_attributes: {
          story_id: "18099013352357043",
          image_type: "ig_story_mention", // NOT the confirmed "ig_story_reply" value
        },
        private: false,
        sender: { id: 1, type: "contact" },
        conversation: { id: 53, custom_attributes: {}, contact_inbox: { contact_id: 1 } },
        account: { id: 42 },
        event: "message_created",
      },
    });
    await new Promise((resolve) => setTimeout(resolve, 100));

    expect(chatBlocking).toHaveBeenCalledTimes(1);
    expect(chatBlocking.mock.calls[0][0].query).toBe("[o usuário enviou uma mídia]");

    await app.close();
  });

  /**
   * `@rev` finding on PR #206 (LOW): an empty/whitespace `story_id` must not
   * count as "present" — that would fabricate a reply out of nothing.
   */
  it("empty-string story_id ⇒ treated as absent, genuinely-empty message stays skipped", async () => {
    const pool = buildFakePool();
    const chatwoot = buildFakeChatwoot();
    const { app } = await buildApp(pool, chatwoot);

    const res = await app.inject({
      method: "POST",
      url: "/webhooks/chatwoot",
      payload: {
        id: 504,
        content: "",
        content_type: 0,
        message_type: "incoming",
        content_attributes: { story_id: "   " },
        private: false,
        sender: { id: 1, type: "contact" },
        conversation: { id: 54, custom_attributes: {}, contact_inbox: { contact_id: 1 } },
        account: { id: 42 },
        event: "message_created",
      },
    });
    expect(res.json()).toEqual({ skipped: "empty_content" });

    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(chatBlocking).not.toHaveBeenCalled();

    await app.close();
  });

  /**
   * `@rev` finding on PR #206 (LOW): the reordering of `accountId`
   * resolution above the empty-content guard is an intentional, observable
   * contract change — a payload with BOTH empty `content` AND a missing
   * `account_id` now gets `400 missing_account_id` (malformed payload)
   * instead of the old `200 skipped:"empty_content"`. Pinned here so it
   * cannot regress silently either way.
   */
  it("empty content AND missing account_id ⇒ 400 missing_account_id (not skipped:empty_content) — intentional contract change", async () => {
    const pool = buildFakePool();
    const chatwoot = buildFakeChatwoot();
    const { app } = await buildApp(pool, chatwoot);

    const res = await app.inject({
      method: "POST",
      url: "/webhooks/chatwoot",
      payload: {
        id: 505,
        content: "",
        content_type: 0,
        message_type: "incoming",
        content_attributes: {},
        private: false,
        sender: { id: 1, type: "contact" },
        conversation: { id: 55, custom_attributes: {}, contact_inbox: { contact_id: 1 } },
        // No `account` object and no top-level `account_id` at all.
        event: "message_created",
      },
    });
    expect(res.statusCode).toBe(400);
    expect(res.json()).toEqual({ error: "missing_account_id" });

    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(chatBlocking).not.toHaveBeenCalled();

    await app.close();
  });

  /**
   * `@rev` finding on PR #206 (MEDIUM, AC of #203): the burst-grouping
   * intersection (#179) was untested for this issue's exact touch point —
   * the marker becoming just another `m.content` string concatenated with
   * `\n` at `flushGroup`'s `:257`. A photo-with-marker followed by a real
   * text reply in the SAME debounce window must produce one coherent query
   * and exactly one outgoing reply, not two.
   */
  it("burst: an empty-content message (marker) + a real-text message in the same window ⇒ ONE coherent query, ONE reply", async () => {
    const pool = buildFakePool();
    const chatwoot = buildFakeChatwoot();
    const { app } = await buildApp(pool, chatwoot);

    await app.inject({
      method: "POST",
      url: "/webhooks/chatwoot",
      payload: {
        ...REAL_MSG_174_STORY_REPLY_PAYLOAD,
        id: 600,
        conversation: { ...REAL_MSG_174_STORY_REPLY_PAYLOAD.conversation, id: 60 },
      },
    });
    await app.inject({
      method: "POST",
      url: "/webhooks/chatwoot",
      payload: {
        id: 601,
        content: "poxa, obrigada!",
        content_type: null,
        message_type: "incoming",
        content_attributes: {},
        private: false,
        sender: { id: 9001, type: "contact" },
        conversation: { id: 60, custom_attributes: {}, contact_inbox: { contact_id: 9001 } },
        account: { id: 42 },
        event: "message_created",
      },
    });
    await new Promise((resolve) => setTimeout(resolve, 150));

    expect(chatBlocking).toHaveBeenCalledTimes(1);
    expect(chatBlocking.mock.calls[0][0].query).toBe(
      "[o usuário respondeu ao seu story]\npoxa, obrigada!",
    );
    expect(chatwoot.postMessage).toHaveBeenCalledTimes(1);
    expect(pool.watermarks.get("42:60")).toBe(601);

    await app.close();
  });

  /**
   * `@rev` finding on PR #206 (MEDIUM, AC of #203): a burst made ENTIRELY of
   * empty-content marker messages must still collapse to one Dify call and
   * one reply, and — same #179 guarantee as any other group — the
   * watermark must advance only AFTER that reply is posted successfully.
   */
  it("burst: two empty-content messages (both markers) in the same window ⇒ ONE reply, watermark advances only after the post succeeds", async () => {
    const pool = buildFakePool();
    const chatwoot = buildFakeChatwoot();
    const { app } = await buildApp(pool, chatwoot);

    await app.inject({
      method: "POST",
      url: "/webhooks/chatwoot",
      payload: {
        ...REAL_MSG_174_STORY_REPLY_PAYLOAD,
        id: 700,
        conversation: { ...REAL_MSG_174_STORY_REPLY_PAYLOAD.conversation, id: 70 },
      },
    });
    await app.inject({
      method: "POST",
      url: "/webhooks/chatwoot",
      payload: {
        ...REAL_MSG_174_STORY_REPLY_PAYLOAD,
        id: 701,
        conversation: { ...REAL_MSG_174_STORY_REPLY_PAYLOAD.conversation, id: 70 },
      },
    });
    await new Promise((resolve) => setTimeout(resolve, 150));

    expect(chatBlocking).toHaveBeenCalledTimes(1);
    expect(chatBlocking.mock.calls[0][0].query).toBe(
      "[o usuário respondeu ao seu story]\n[o usuário respondeu ao seu story]",
    );
    expect(chatwoot.postMessage).toHaveBeenCalledTimes(1);
    // Watermark only advances once the reply has actually been posted.
    expect(pool.watermarks.get("42:70")).toBe(701);

    await app.close();
  });

  it("burst of only-marker messages: a failed reply post must NOT advance the watermark", async () => {
    const pool = buildFakePool();
    const chatwoot = buildFakeChatwoot();
    chatwoot.postMessage.mockRejectedValueOnce(new Error("chatwoot unreachable"));
    chatwoot.postMessage.mockResolvedValueOnce({
      id: 2,
      content: "",
      private: true,
      message_type: "outgoing",
      created_at: "",
    });
    const { app } = await buildApp(pool, chatwoot);

    await app.inject({
      method: "POST",
      url: "/webhooks/chatwoot",
      payload: {
        ...REAL_MSG_174_STORY_REPLY_PAYLOAD,
        id: 800,
        conversation: { ...REAL_MSG_174_STORY_REPLY_PAYLOAD.conversation, id: 80 },
      },
    });
    await app.inject({
      method: "POST",
      url: "/webhooks/chatwoot",
      payload: {
        ...REAL_MSG_174_STORY_REPLY_PAYLOAD,
        id: 801,
        conversation: { ...REAL_MSG_174_STORY_REPLY_PAYLOAD.conversation, id: 80 },
      },
    });
    await new Promise((resolve) => setTimeout(resolve, 150));

    expect(chatBlocking).toHaveBeenCalledTimes(1);
    // First postMessage call (the outgoing reply) failed; the watermark
    // must stay unset so a redelivery is still answered.
    expect(pool.watermarks.get("42:80")).toBeUndefined();

    await app.close();
  });
});
