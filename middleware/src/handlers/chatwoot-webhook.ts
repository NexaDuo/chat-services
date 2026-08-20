import type { FastifyInstance, FastifyBaseLogger } from "fastify";
import { z } from "zod";
import axios from "axios";
import pg from "pg";
import type { AppConfig } from "../config.js";
import { resolveTenant } from "../config.js";
import type { Metrics } from "../metrics.js";
import type { ChatwootClient } from "../chatwoot.js";
import { DifyClient } from "../dify.js";
import { timingSafeEqual } from "node:crypto";
import { ConversationDebouncer } from "../conversation-debouncer.js";

/**
 * Constant-time token comparison. A plain `!==` leaks the length of the
 * matching prefix through timing, which is exploitable against an endpoint
 * an attacker can call repeatedly — and this webhook is reachable from the
 * public tunnel. Length is compared first (and non-secret), then the bytes.
 */
export function safeTokenEqual(candidate: string, expected: string): boolean {
  const a = Buffer.from(candidate, "utf8");
  const b = Buffer.from(expected, "utf8");
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

/**
 * Picks the webhook token out of the request, preferring the header.
 *
 * Chatwoot's generic webhooks cannot send custom headers, so its token
 * arrives as `?token=...`. Internal callers CAN set a header, and those keep
 * the secret out of URLs and access logs — hence the precedence.
 *
 * A present-but-wrong header does NOT fall back to the query: falling back
 * would let an attacker who can only set a header downgrade to whichever
 * channel they control. A repeated parameter (`?token=a&token=b`) parses to
 * an array, which is ambiguous — it is rejected, but still reported as
 * `"query"` so a 401 is diagnosable.
 */
export function extractWebhookToken(
  headerToken: unknown,
  queryToken: unknown,
): { token?: string; source: "header" | "query" | "none" } {
  if (typeof headerToken === "string") return { token: headerToken, source: "header" };
  if (Array.isArray(headerToken)) return { source: "header" };
  if (typeof queryToken === "string") return { token: queryToken, source: "query" };
  if (Array.isArray(queryToken)) return { source: "query" };
  return { source: "none" };
}

/**
 * Chatwoot webhook payload (partial — only the fields we care about).
 * See: https://www.chatwoot.com/docs/product/channels/api/send-messages
 */
const WebhookSchema = z
  .object({
    event: z.string(),
    message_type: z.string().optional(),
    content: z.string().nullable().optional(),
    private: z.boolean().optional(),
    account: z
      .object({ id: z.union([z.number(), z.string()]) })
      .passthrough()
      .optional(),
    conversation: z
      .object({
        id: z.union([z.number(), z.string()]),
        custom_attributes: z
          .record(z.string(), z.unknown())
          .optional()
          .default({}),
        contact_inbox: z
          .object({
            contact_id: z.union([z.number(), z.string()]).optional(),
          })
          .partial()
          .optional(),
      })
      .passthrough(),
    sender: z
      .object({
        type: z.string().optional(),
        id: z.union([z.number(), z.string()]).optional(),
      })
      .partial()
      .optional(),
    // Chatwoot's real message_created payload carries the message id and
    // creation timestamp at the top level (see
    // https://www.chatwoot.com/docs/product/channels/api/receive-messages).
    // Both are optional here purely defensively — the watermark logic below
    // degrades to "not persisted for this message" rather than throwing if
    // either is ever missing, instead of 400-ing a webhook Chatwoot actually
    // sent.
    id: z.union([z.number(), z.string()]).optional(),
    created_at: z.union([z.number(), z.string()]).optional(),
  })
  .passthrough();

const DIFY_CONV_ID_ATTR = "dify_conversation_id";

/** One incoming message buffered for grouping, per issue #179. */
type BufferedIncomingMessage = {
  /** Chatwoot message id — used for the watermark, and for chronological sort. */
  id: number | undefined;
  content: string;
  accountIdStr: string;
  conversationId: number | string;
  contactId: number | string;
  /** dify_conversation_id as read from THIS webhook's custom_attributes, if any. */
  difyConvIdHint?: string;
};

function watermarkKey(accountIdStr: string, conversationId: number | string): string {
  return `${accountIdStr}:${conversationId}`;
}

/** Reads the persisted watermark for a conversation. Defaults to 0 (never processed). */
async function readWatermark(
  pool: pg.Pool,
  accountIdStr: string,
  conversationId: number | string,
): Promise<number> {
  const result = await pool.query(
    "SELECT last_processed_message_id FROM conversation_watermarks WHERE account_id = $1 AND conversation_id = $2",
    [accountIdStr, String(conversationId)],
  );
  if (result.rows.length === 0) return 0;
  return Number(result.rows[0].last_processed_message_id) || 0;
}

/**
 * Persists the watermark as the max of the stored value and `messageId`
 * (never regresses it) — an UPSERT, so it doubles as the row-level lock the
 * design calls for. Called ONLY after the outgoing message has been posted
 * successfully; a failed post must never advance this.
 */
async function persistWatermark(
  pool: pg.Pool,
  accountIdStr: string,
  conversationId: number | string,
  messageId: number,
): Promise<void> {
  await pool.query(
    `INSERT INTO conversation_watermarks (account_id, conversation_id, last_processed_message_id)
     VALUES ($1, $2, $3)
     ON CONFLICT (account_id, conversation_id)
     DO UPDATE SET
       last_processed_message_id = GREATEST(conversation_watermarks.last_processed_message_id, EXCLUDED.last_processed_message_id),
       updated_at = CURRENT_TIMESTAMP`,
    [accountIdStr, String(conversationId), messageId],
  );
}

/**
 * Handles one already-grouped burst: resolves the tenant fresh (in case the
 * mapping changed since the messages arrived), calls Dify exactly once with
 * the concatenated content, posts exactly one outgoing reply, and — only on
 * success — advances the persisted watermark. See issue #179.
 */
async function flushGroup(
  group: { key: string; messages: BufferedIncomingMessage[] },
  deps: {
    app: FastifyInstance;
    config: AppConfig;
    metrics: Metrics;
    chatwoot: ChatwootClient;
    pool: pg.Pool;
    difyConvIdCache: Map<string, string>;
  },
): Promise<void> {
  const { app, config, metrics, chatwoot, pool, difyConvIdCache } = deps;
  const log: FastifyBaseLogger = app.log;
  const first = group.messages[0];
  const accountIdStr = first.accountIdStr;
  const conversationId = first.conversationId;
  const contactId =
    group.messages.find((m) => m.contactId !== "unknown")?.contactId ?? "unknown";

  // Defensive re-filter against the persisted watermark: protects against a
  // webhook retry/redelivery landing in the same group as a message already
  // accounted for, and against messages whose id we could not parse (kept
  // in the group for content, but never allowed to move the watermark).
  const watermark = await readWatermark(pool, accountIdStr, conversationId);
  const eligible = group.messages
    .filter((m) => m.id === undefined || m.id > watermark)
    .sort((a, b) => (a.id ?? 0) - (b.id ?? 0));

  if (eligible.length === 0) {
    log.info(
      { accountId: accountIdStr, conversationId, watermark },
      "webhook: group fully below watermark, skipping (duplicate delivery)",
    );
    return;
  }

  const content = eligible.map((m) => m.content).join("\n");
  const maxId = eligible.reduce(
    (max, m) => (m.id !== undefined && m.id > max ? m.id : max),
    0,
  );

  const tenant = await resolveTenant(config, accountIdStr, pool);
  if (!tenant) {
    log.warn({ accountId: accountIdStr }, "webhook: no tenant mapping (group dropped)");
    metrics.errorsTotal.inc({ account_id: accountIdStr, reason: "no_tenant_mapping" });
    return;
  }

  const difyConvId =
    difyConvIdCache.get(group.key) ??
    group.messages.find((m) => m.difyConvIdHint)?.difyConvIdHint;

  const dify = new DifyClient(
    tenant.baseUrl,
    tenant.apiKey,
    config.dify.requestTimeoutMs,
    log,
  );

  const start = process.hrtime.bigint();
  try {
    const chatReq = {
      query: content,
      user: `${accountIdStr}:${contactId}`,
      conversationId: difyConvId,
      inputs: {
        chatwoot_account_id: accountIdStr,
        chatwoot_conversation_id: String(conversationId),
        chatwoot_contact_id: String(contactId),
      },
    };
    const difyResp = tenant.appType === "agent"
      ? await dify.chatStreaming(chatReq)
      : await dify.chatBlocking(chatReq);

    const durationS = Number(process.hrtime.bigint() - start) / 1_000_000_000;
    metrics.difyRequestsTotal.inc({ account_id: accountIdStr, status: "ok" });
    metrics.difyRequestDuration.observe({ account_id: accountIdStr, status: "ok" }, durationS);
    if (difyResp.metadata?.usage?.prompt_tokens) {
      metrics.difyTokensTotal.inc(
        { account_id: accountIdStr, kind: "prompt" },
        difyResp.metadata.usage.prompt_tokens,
      );
    }
    if (difyResp.metadata?.usage?.completion_tokens) {
      metrics.difyTokensTotal.inc(
        { account_id: accountIdStr, kind: "completion" },
        difyResp.metadata.usage.completion_tokens,
      );
    }

    // Persist Dify conversation_id on first turn for memory continuity.
    if (!difyConvId && difyResp.conversation_id) {
      difyConvIdCache.set(group.key, difyResp.conversation_id);
      try {
        await chatwoot.setConversationCustomAttributes({
          accountId: accountIdStr,
          conversationId,
          attributes: { [DIFY_CONV_ID_ATTR]: difyResp.conversation_id },
        });
      } catch (err) {
        log.warn({ err }, "webhook: failed to persist dify_conversation_id (non-fatal)");
      }
    }

    // Post the agent's answer back to the user — exactly once for the group.
    await chatwoot.postMessage({
      accountId: accountIdStr,
      conversationId,
      content: difyResp.answer,
      messageType: "outgoing",
    });

    // Only advance the watermark AFTER the reply was posted successfully —
    // a failure here must not make the group look "already handled".
    if (maxId > 0) {
      await persistWatermark(pool, accountIdStr, conversationId, maxId);
    }
  } catch (err) {
    const durationS = Number(process.hrtime.bigint() - start) / 1_000_000_000;
    metrics.difyRequestsTotal.inc({ account_id: accountIdStr, status: "error" });
    metrics.difyRequestDuration.observe({ account_id: accountIdStr, status: "error" }, durationS);

    const isTimeout =
      axios.isAxiosError(err) &&
      (err.code === "ECONNABORTED" || err.message.includes("timeout"));
    const reason = isTimeout ? "dify_timeout" : "dify_error";
    metrics.errorsTotal.inc({ account_id: accountIdStr, reason });

    log.error(
      { err, accountId: accountIdStr, conversationId, isTimeout, groupSize: eligible.length },
      "webhook: dify call failed for group",
    );

    // Drop a private note so the human team has context. Best-effort: a
    // failure to post the note must not mask the original error.
    try {
      const note =
        `[middleware] Falha ao processar mensagem(ns) via Dify (${reason}).\n` +
        `Motivo: ${(err as Error).message ?? "desconhecido"}`;
      await chatwoot.postMessage({
        accountId: accountIdStr,
        conversationId,
        content: note,
        private: true,
      });
    } catch (postErr) {
      log.error({ err: postErr }, "webhook: also failed to post error note to Chatwoot");
    }
    // Deliberately re-thrown so the debouncer's onError hook can log the
    // key too; watermark is already un-advanced above.
    throw err;
  }
}

export async function registerChatwootWebhookRoute(
  app: FastifyInstance,
  config: AppConfig,
  metrics: Metrics,
  chatwoot: ChatwootClient,
  pool: pg.Pool,
): Promise<void> {
  // dify_conversation_id per conversation key, freshest-wins cache so a
  // burst that arrives before Chatwoot's custom_attributes write lands
  // (or before we've re-read it) still gets the right Dify thread.
  const difyConvIdCache = new Map<string, string>();

  const debouncer = new ConversationDebouncer<BufferedIncomingMessage>(
    config.webhook.debounceMs,
    (group) => flushGroup(group, { app, config, metrics, chatwoot, pool, difyConvIdCache }),
    (key, err) => {
      app.log.error({ key, err }, "webhook: group flush failed (see prior log line for detail)");
    },
  );

  app.post("/webhooks/chatwoot", async (req, reply) => {
    // 1. Authenticate webhook if token is configured
    if (config.chatwoot.webhookToken) {
      // Chatwoot's generic webhooks cannot send custom headers, so the token
      // arrives in the query string (`?token=...`) — that is the only channel
      // Chatwoot offers. We still prefer a header when present so internal
      // callers (which CAN set one) keep the token out of URLs and access logs.
      const { token, source } = extractWebhookToken(
        req.headers["x-chatwoot-webhook-token"],
        (req.query as { token?: unknown } | undefined)?.token,
      );

      if (!token || !safeTokenEqual(token, config.chatwoot.webhookToken)) {
        req.log.warn(
          { hasToken: !!token, tokenSource: source },
          "webhook: unauthorized (invalid token)",
        );
        return reply.code(401).send({ error: "unauthorized" });
      }
    } else {
      req.log.warn("webhook: CHATWOOT_WEBHOOK_TOKEN not configured, skipping auth");
    }

    const parsed = WebhookSchema.safeParse(req.body);
    if (!parsed.success) {
      req.log.warn({ issues: parsed.error.issues }, "webhook: invalid payload");
      return reply.code(400).send({ error: "invalid_payload" });
    }
    const evt = parsed.data;

    // Only react to fresh incoming messages from real contacts.
    if (evt.event !== "message_created") {
      return reply.code(200).send({ skipped: "not_message_created" });
    }
    if (evt.message_type !== "incoming") {
      return reply.code(200).send({ skipped: "not_incoming" });
    }
    if (evt.private === true) {
      return reply.code(200).send({ skipped: "private_note" });
    }
    if (evt.sender?.type && evt.sender.type.toLowerCase() !== "contact") {
      return reply.code(200).send({ skipped: "not_contact_sender" });
    }
    const content = (evt.content ?? "").trim();
    if (!content) {
      return reply.code(200).send({ skipped: "empty_content" });
    }

    // Chatwoot payload shape: account_id may live under evt.account.id OR at
    // top-level. Same for conversation/contact. We prefer the nested fields
    // which are present on standard webhooks.
    const accountId = evt.account?.id ?? (req.body as { account_id?: unknown })["account_id"];
    if (accountId === undefined || accountId === null) {
      return reply.code(400).send({ error: "missing_account_id" });
    }
    const conversationId = evt.conversation.id;
    const contactId = evt.conversation.contact_inbox?.contact_id ?? "unknown";
    const accountIdStr = String(accountId);

    // Cheap tenant-existence check on the hot path (kept — this is a fast
    // read that lets us 200-and-skip a truly unmapped account without ever
    // buffering it). The full tenant lookup happens again at flush time,
    // since that is when it actually gets used against Dify and a burst can
    // straddle a tenant-mapping change.
    const tenant = await resolveTenant(config, accountIdStr, pool);
    if (!tenant) {
      req.log.warn({ accountId: accountIdStr }, "webhook: no tenant mapping");
      metrics.errorsTotal.inc({
        account_id: accountIdStr,
        reason: "no_tenant_mapping",
      });
      return reply.code(200).send({ skipped: "no_tenant_mapping" });
    }

    const difyConvId =
      (evt.conversation.custom_attributes?.[DIFY_CONV_ID_ATTR] as
        | string
        | undefined) ?? undefined;

    const rawId = evt.id;
    const numericId =
      rawId === undefined
        ? undefined
        : typeof rawId === "number"
          ? rawId
          : Number.isFinite(Number(rawId))
            ? Number(rawId)
            : undefined;
    if (numericId === undefined) {
      req.log.warn(
        { accountId: accountIdStr, conversationId },
        "webhook: message_created without a parseable id — content will be grouped but cannot advance the watermark",
      );
    }

    // 2. Buffer the message and (re)arm the debounce timer for this
    // conversation — this is the fix for issue #179. Do NOT call Dify here:
    // the burst that triggered this fix is exactly two `message_created`
    // webhooks ~1.5s apart for the same conversation, each of which used to
    // call Dify (and post an outgoing reply) independently. Grouping means
    // the actual Dify call + reply happen once, asynchronously, in
    // `flushGroup` — so we ack Chatwoot immediately and let the debouncer
    // decide when the group is complete.
    debouncer.enqueue(watermarkKey(accountIdStr, conversationId), {
      id: numericId,
      content,
      accountIdStr,
      conversationId,
      contactId,
      difyConvIdHint: difyConvId,
    });

    return reply.code(200).send({ ok: true, buffered: true });
  });
}
