import { FastifyInstance } from "fastify";
import { AppConfig } from "../config.js";
import pg from "pg";

/**
 * Registers the tenant resolution API route.
 * Used by Cloudflare Workers to map subdomains to Chatwoot account IDs.
 */
export async function registerTenantRoute(
  app: FastifyInstance,
  config: AppConfig,
): Promise<void> {
  const pool = new pg.Pool({ connectionString: config.databaseUrl });

  app.get("/resolve-tenant", async (request, reply) => {
    const authHeader = request.headers.authorization;
    const expectedToken = `Bearer ${config.handoff.sharedSecret}`;

    if (!authHeader || authHeader !== expectedToken) {
      return reply.code(401).send({ error: "Unauthorized" });
    }

    const { subdomain } = request.query as { subdomain: string };

    if (!subdomain) {
      return reply.code(400).send({ error: "Subdomain query parameter is required" });
    }

    try {
      const result = await pool.query(
        "SELECT chatwoot_account_id FROM tenants WHERE subdomain = $1",
        [subdomain]
      );
      
      if (result.rows.length === 0) {
        return reply.code(404).send({ error: "Tenant not found" });
      }

      return {
        subdomain,
        accountId: result.rows[0].chatwoot_account_id,
      };
    } catch (err) {
      app.log.error({ err, subdomain }, "Failed to fetch tenant from database");
      return reply.code(500).send({ error: "Internal Server Error" });
    }
  });
}
