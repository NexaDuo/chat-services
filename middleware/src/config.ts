import { z } from "zod";

const EnvSchema = z.object({
  PORT: z.coerce.number().int().positive().default(4000),
  LOG_LEVEL: z
    .enum(["trace", "debug", "info", "warn", "error", "fatal"])
    .default("info"),

  CHATWOOT_BASE_URL: z.string().url(),
  CHATWOOT_API_TOKEN: z.string().default(""),
  CHATWOOT_WEBHOOK_TOKEN: z.string().optional(),

  DIFY_BASE_URL: z.string().url(),
  DIFY_REQUEST_TIMEOUT_MS: z.coerce.number().int().positive().default(30000),

  HANDOFF_SHARED_SECRET: z
    .string()
    .min(16, "HANDOFF_SHARED_SECRET must be at least 16 chars"),
  HANDOFF_LABEL: z.string().default("atendimento-humano"),

  DATABASE_URL: z.string().url().min(1, "DATABASE_URL is required"),
});

export type AppConfig = {
  port: number;
  logLevel: z.infer<typeof EnvSchema>["LOG_LEVEL"];
  databaseUrl: string;
  chatwoot: {
    baseUrl: string;
    apiToken: string;
    webhookToken?: string;
  };
  dify: {
    baseUrl: string;
    requestTimeoutMs: number;
  };
  handoff: {
    sharedSecret: string;
    label: string;
  };
};

/**
 * Loads and validates all env vars. Throws (fail-fast) on invalid config.
 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  const parsed = EnvSchema.safeParse(env);
  if (!parsed.success) {
    const issues = parsed.error.issues
      .map((i) => `${i.path.join(".") || "(root)"}: ${i.message}`)
      .join("\n  - ");
    throw new Error(`Invalid environment configuration:\n  - ${issues}`);
  }
  const data = parsed.data;
  return {
    port: data.PORT,
    logLevel: data.LOG_LEVEL,
    databaseUrl: data.DATABASE_URL,
    chatwoot: {
      baseUrl: data.CHATWOOT_BASE_URL.replace(/\/+$/, ""),
      apiToken: data.CHATWOOT_API_TOKEN,
      webhookToken: data.CHATWOOT_WEBHOOK_TOKEN,
    },
    dify: {
      baseUrl: data.DIFY_BASE_URL.replace(/\/+$/, ""),
      requestTimeoutMs: data.DIFY_REQUEST_TIMEOUT_MS,
    },
    handoff: {
      sharedSecret: data.HANDOFF_SHARED_SECRET,
      label: data.HANDOFF_LABEL,
    },
  };
}

/**
 * Resolves the per-tenant Dify config for a given Chatwoot account_id from database.
 * Returns `null` if the account is not mapped.
 */
export async function resolveTenant(
  config: AppConfig,
  accountId: string | number,
  pool: import("pg").Pool,
): Promise<{ apiKey: string; baseUrl: string; appType: "chatflow" | "agent" } | null> {
  const key = String(accountId);

  try {
    const result = await pool.query(
      "SELECT dify_api_key, dify_app_type FROM tenants WHERE chatwoot_account_id = $1",
      [key]
    );
    if (result.rows.length > 0) {
      const row = result.rows[0];
      return {
        apiKey: row.dify_api_key,
        baseUrl: config.dify.baseUrl,
        appType: row.dify_app_type as "chatflow" | "agent",
      };
    }
  } catch (err) {
    console.error("Failed to resolve tenant from database", err);
  }

  return null;
}
