import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { AppConfig } from "../config.js";
import type { Metrics } from "../metrics.js";
import type { ChatwootClient } from "../chatwoot.js";

const HandoffBodySchema = z.object({
  account_id: z.union([z.string(), z.number()]),
  conversation_id: z.union([z.string(), z.number()]),
  summary: z.string().min(1).max(4000),
});

/**
 * Called by Dify as an HTTP Tool when the agent decides to hand off to a human.
 *
 * Authentication: shared secret via `x-handoff-secret` header.
 *
 * Actions:
 *   1. Re-open the Chatwoot conversation (status → "open").
 *   2. Add label (default `atendimento-humano`).
 *   3. Append a private note with the agent's summary for the human rep.
 */
export async function registerHandoffRoute(
  app: FastifyInstance,
  config: AppConfig,
  metrics: Metrics,
  chatwoot: ChatwootClient,
): Promise<void> {
  app.post("/tools/handoff", async (req, reply) => {
    const secret = req.headers["x-handoff-secret"];
    if (
      typeof secret !== "string" ||
      secret.length === 0 ||
      secret !== config.handoff.sharedSecret
    ) {
      return reply.code(401).send({ error: "unauthorized" });
    }

    const parsed = HandoffBodySchema.safeParse(req.body);
    if (!parsed.success) {
      return reply
        .code(400)
        .send({ error: "invalid_payload", issues: parsed.error.issues });
    }
    const { account_id, conversation_id, summary } = parsed.data;
    const accountIdStr = String(account_id);

    try {
      await chatwoot.toggleConversationStatus({
        accountId: account_id,
        conversationId: conversation_id,
        status: "open",
      });
      await chatwoot.addLabels({
        accountId: account_id,
        conversationId: conversation_id,
        labels: [config.handoff.label],
      });
      await chatwoot.postMessage({
        accountId: account_id,
        conversationId: conversation_id,
        content: `**Handoff solicitado pelo agente IA**\n\n${summary}`,
        private: true,
      });
      metrics.handoffsTotal.inc({ account_id: accountIdStr });
      req.log.info(
        { accountId: accountIdStr, conversationId: String(conversation_id) },
        "handoff: success",
      );
      return reply.code(200).send({ ok: true });
    } catch (err) {
      metrics.errorsTotal.inc({
        account_id: accountIdStr,
        reason: "handoff_failed",
      });
      req.log.error({ err }, "handoff: failed");
      return reply.code(502).send({ error: "handoff_failed" });
    }
  });
}
