import { FastifyInstance } from "fastify";
import { AppConfig } from "../config.js";
import pg from "pg";

/**
 * Registers the configuration API route.
 * Used by internal agents (like self-healing) to fetch settings from Postgres.
 */
export async function registerConfigRoute(
  app: FastifyInstance,
  config: AppConfig,
): Promise<void> {
  const pool = config.databaseUrl 
    ? new pg.Pool({ connectionString: config.databaseUrl }) 
    : null;

  // GET /config - List all configs or a specific one
  app.get("/config", async (request, reply) => {
    const authHeader = request.headers.authorization;
    const expectedToken = `Bearer ${config.handoff.sharedSecret}`;

    if (!authHeader || authHeader !== expectedToken) {
      return reply.code(401).send({ error: "Unauthorized" });
    }

    let dbConfigs: Record<string, string> = {};
    
    if (pool) {
      try {
        const result = await pool.query("SELECT key, value FROM configs");
        dbConfigs = result.rows.reduce((acc, row) => {
          acc[row.key] = row.value;
          return acc;
        }, {} as Record<string, string>);
      } catch (err) {
        app.log.error({ err }, "Failed to fetch configs from database");
      }
    }

    // Merge logic: DB overrides Env (if env existed, but we removed it)
    return {
      dify: {
        selfHealingApiKey: dbConfigs["DIFY_SELF_HEALING_API_KEY"],
      },
      // All other DB-only configs
      db: dbConfigs,
    };
  });

  // POST /config - Update or create a config key
  app.post("/config", async (request, reply) => {
    const authHeader = request.headers.authorization;
    const expectedToken = `Bearer ${config.handoff.sharedSecret}`;

    if (!authHeader || authHeader !== expectedToken) {
      return reply.code(401).send({ error: "Unauthorized" });
    }

    if (!pool) {
      return reply.code(400).send({ error: "Database not configured" });
    }

    const { key, value } = request.body as { key: string; value: string };
    
    if (!key) {
      return reply.code(400).send({ error: "Key is required" });
    }

    try {
      await pool.query(
        "INSERT INTO configs (key, value, updated_at) VALUES ($1, $2, NOW()) ON CONFLICT (key) DO UPDATE SET value = $2, updated_at = NOW()",
        [key, value]
      );
      return { success: true, key };
    } catch (err) {
      app.log.error({ err }, "Failed to save config to database");
      return reply.code(500).send({ error: "Internal Server Error" });
    }
  });
}
