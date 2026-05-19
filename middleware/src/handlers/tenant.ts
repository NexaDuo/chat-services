import { FastifyInstance } from "fastify";
import { z } from "zod";
import { AppConfig } from "../config.js";
import pg from "pg";

const ResolveTenantQuerySchema = z.object({
  subdomain: z.string().min(1),
});

/**
 * Registers the tenant resolution API route.
 * Used by Cloudflare Workers to map subdomains to Chatwoot account IDs.
 */
export async function registerTenantRoute(
  app: FastifyInstance,
  config: AppConfig,
  pool: pg.Pool,
): Promise<void> {
  app.get("/resolve-tenant", async (request, reply) => {
    const authHeader = request.headers.authorization;
    const expectedToken = `Bearer ${config.handoff.sharedSecret}`;

    if (!authHeader || authHeader !== expectedToken) {
      return reply.code(401).send({ error: "unauthorized" });
    }

    const parsed = ResolveTenantQuerySchema.safeParse(request.query);
    if (!parsed.success) {
      return reply.code(400).send({ 
        error: "invalid_query", 
        issues: parsed.error.issues 
      });
    }

    const { subdomain } = parsed.data;

    try {
      const result = await pool.query(
        "SELECT chatwoot_account_id, infra_type, chatwoot_url, dify_url FROM tenants WHERE subdomain = $1",
        [subdomain]
      );
      
      if (result.rows.length === 0) {
        return reply.code(404).send({ error: "tenant_not_found" });
      }

      const row = result.rows[0];
      return reply.code(200).send({
        subdomain,
        accountId: row.chatwoot_account_id,
        infraType: row.infra_type,
        overrides: {
          chatwootUrl: row.chatwoot_url,
          difyUrl: row.dify_url
        }
      });
    } catch (err) {
      app.log.error({ err, subdomain }, "Failed to fetch tenant from database");
      return reply.code(500).send({ error: "internal_server_error" });
    }
  });
}
