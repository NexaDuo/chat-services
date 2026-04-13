import Fastify from "fastify";
import sensible from "@fastify/sensible";
import { loadConfig } from "./config.js";
import { buildFastifyLoggerConfig } from "./logger.js";
import { createMetrics } from "./metrics.js";
import { ChatwootClient } from "./chatwoot.js";
import { registerHealthRoutes } from "./handlers/health.js";
import { registerChatwootWebhookRoute } from "./handlers/chatwoot-webhook.js";
import { registerHandoffRoute } from "./handlers/handoff.js";
import { registerConfigRoute } from "./handlers/config.js";
import { registerTenantRoute } from "./handlers/tenant.js";

async function main(): Promise<void> {
  let config;
  try {
    config = loadConfig();
  } catch (err) {
    // Config must be valid before we can even set up logging.
    // eslint-disable-next-line no-console
    console.error((err as Error).message);
    process.exit(1);
  }

  const app = Fastify({
    logger: buildFastifyLoggerConfig(config.logLevel),
    disableRequestLogging: false,
    bodyLimit: 5 * 1024 * 1024, // 5 MiB — Chatwoot webhooks can carry attachments metadata
    trustProxy: true,
  });

  const metrics = createMetrics();
  const chatwoot = new ChatwootClient(
    config.chatwoot.baseUrl,
    config.chatwoot.apiToken,
    app.log,
  );

  await app.register(sensible);

  await registerHealthRoutes(app, metrics);
  await registerChatwootWebhookRoute(app, config, metrics, chatwoot);
  await registerHandoffRoute(app, config, metrics, chatwoot);
  await registerConfigRoute(app, config);
  await registerTenantRoute(app, config);

  const shutdown = async (signal: string): Promise<void> => {
    app.log.info({ signal }, "middleware: shutting down");
    try {
      await app.close();
      process.exit(0);
    } catch (err) {
      app.log.error({ err }, "middleware: error during shutdown");
      process.exit(1);
    }
  };

  process.on("SIGTERM", () => void shutdown("SIGTERM"));
  process.on("SIGINT", () => void shutdown("SIGINT"));

  try {
    await app.listen({ port: config.port, host: "0.0.0.0" });
    app.log.info(
      {
        port: config.port,
        chatwootBaseUrl: config.chatwoot.baseUrl,
        difyBaseUrl: config.dify.baseUrl,
      },
      "middleware: listening",
    );
  } catch (err) {
    app.log.error({ err }, "middleware: failed to listen");
    process.exit(1);
  }
}

void main();
