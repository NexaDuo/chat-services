import type { FastifyInstance } from "fastify";
import { z } from "zod";
import axios from "axios";
import type { AppConfig } from "../config.js";
import { resolveTenant } from "../config.js";
import type { Metrics } from "../metrics.js";
import type { ChatwootClient } from "../chatwoot.js";
import { DifyClient } from "../dify.js";

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
  })
  .passthrough();

const DIFY_CONV_ID_ATTR = "dify_conversation_id";

export async function registerChatwootWebhookRoute(
  app: FastifyInstance,
  config: AppConfig,
  metrics: Metrics,
  chatwoot: ChatwootClient,
): Promise<void> {
  app.post("/webhooks/chatwoot", async (req, reply) => {
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
    const tenant = resolveTenant(config, accountIdStr);
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

    const dify = new DifyClient(
      tenant.baseUrl,
      tenant.apiKey,
      config.dify.requestTimeoutMs,
      req.log,
    );

    const start = process.hrtime.bigint();
    try {
      const difyResp = await dify.chatBlocking({
        query: content,
        user: `${accountIdStr}:${contactId}`,
        conversationId: difyConvId,
        inputs: {
          chatwoot_account_id: accountIdStr,
          chatwoot_conversation_id: String(conversationId),
          chatwoot_contact_id: String(contactId),
        },
      });

      const durationS =
        Number(process.hrtime.bigint() - start) / 1_000_000_000;
      metrics.difyRequestsTotal.inc({
        account_id: accountIdStr,
        status: "ok",
      });
      metrics.difyRequestDuration.observe(
        { account_id: accountIdStr, status: "ok" },
        durationS,
      );
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
        try {
          await chatwoot.setConversationCustomAttributes({
            accountId: accountIdStr,
            conversationId,
            attributes: { [DIFY_CONV_ID_ATTR]: difyResp.conversation_id },
          });
        } catch (err) {
          req.log.warn(
            { err },
            "webhook: failed to persist dify_conversation_id (non-fatal)",
          );
        }
      }

      // Post the agent's answer back to the user.
      await chatwoot.postMessage({
        accountId: accountIdStr,
        conversationId,
        content: difyResp.answer,
        messageType: "outgoing",
      });

      return reply.code(200).send({ ok: true });
    } catch (err) {
      const durationS =
        Number(process.hrtime.bigint() - start) / 1_000_000_000;
      metrics.difyRequestsTotal.inc({
        account_id: accountIdStr,
        status: "error",
      });
      metrics.difyRequestDuration.observe(
        { account_id: accountIdStr, status: "error" },
        durationS,
      );

      const isTimeout =
        axios.isAxiosError(err) &&
        (err.code === "ECONNABORTED" || err.message.includes("timeout"));
      const reason = isTimeout ? "dify_timeout" : "dify_error";
      metrics.errorsTotal.inc({ account_id: accountIdStr, reason });

      req.log.error(
        {
          err,
          accountId: accountIdStr,
          conversationId,
          isTimeout,
        },
        "webhook: dify call failed",
      );

      // Drop a private note so the human team has context.
      try {
        const note =
          `[middleware] Falha ao processar mensagem via Dify (${reason}).\n` +
          `Motivo: ${(err as Error).message ?? "desconhecido"}`;
        await chatwoot.postMessage({
          accountId: accountIdStr,
          conversationId,
          content: note,
          private: true,
        });
      } catch (postErr) {
        req.log.error(
          { err: postErr },
          "webhook: also failed to post error note to Chatwoot",
        );
      }

      return reply.code(502).send({ error: reason });
    }
  });
}
