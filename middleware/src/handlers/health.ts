import type { FastifyInstance } from "fastify";
import type { Metrics } from "../metrics.js";

export async function registerHealthRoutes(
  app: FastifyInstance,
  metrics: Metrics,
): Promise<void> {
  app.get("/health", async () => ({
    status: "ok",
    uptimeSeconds: Math.round(process.uptime()),
  }));

  app.get("/metrics", async (_req, reply) => {
    reply.type(metrics.registry.contentType);
    return metrics.registry.metrics();
  });
}
