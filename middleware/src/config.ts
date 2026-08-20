import { z } from "zod";

const EnvSchema = z.object({
  PORT: z.coerce.number().int().positive().default(4000),
  LOG_LEVEL: z
    .enum(["trace", "debug", "info", "warn", "error", "fatal"])
    .default("info"),

  CHATWOOT_PLATFORM_TOKEN: z.string().optional(),
  CHATWOOT_BASE_URL: z.string().url(),
  CHATWOOT_API_TOKEN: z.string().default(""),
  CHATWOOT_WEBHOOK_TOKEN: z.string().optional(),

  DIFY_BASE_URL: z.string().url(),
  DIFY_REQUEST_TIMEOUT_MS: z.coerce.number().int().positive().default(30000),

  // Burst-dedup debounce window (issue #179): a message-burst window during
  // which incoming messages for the same conversation are grouped into a
  // single Dify call instead of one call per message. 0 disables grouping
  // (each message flushes on its own, still serialized per conversation).
  WEBHOOK_DEBOUNCE_MS: z.coerce.number().int().nonnegative().default(2500),

  HANDOFF_SHARED_SECRET: z
    .string()
    .min(16, "HANDOFF_SHARED_SECRET must be at least 16 chars"),
  HANDOFF_LABEL: z.string().default("atendimento-humano"),

  ADMIN_PASSWORD: z.string().optional(),
  EVOLUTION_AUTHENTICATION_API_KEY: z.string().optional(),
  EVOLUTION_BASE_URL: z.string().url().default("http://evolution-api:8080"),
  DATABASE_URL: z.string().url().min(1, "DATABASE_URL is required"),
});

export type AppConfig = {
  port: number;
  logLevel: z.infer<typeof EnvSchema>["LOG_LEVEL"];
  databaseUrl: string;
  adminPassword?: string;
  evolution: {
    apiKey?: string;
    baseUrl: string;
  };
  chatwoot: {
    baseUrl: string;
    apiToken: string;
    platformToken?: string;
    webhookToken?: string;
  };
  dify: {
    baseUrl: string;
    requestTimeoutMs: number;
  };
  webhook: {
    debounceMs: number;
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
    adminPassword: data.ADMIN_PASSWORD,
    evolution: {
      apiKey: data.EVOLUTION_AUTHENTICATION_API_KEY,
      baseUrl: data.EVOLUTION_BASE_URL.replace(/\/+$/, ""),
    },
    chatwoot: {
      baseUrl: data.CHATWOOT_BASE_URL.replace(/\/+$/, ""),
      apiToken: data.CHATWOOT_API_TOKEN,
      platformToken: data.CHATWOOT_PLATFORM_TOKEN,
      webhookToken: data.CHATWOOT_WEBHOOK_TOKEN,
    },

    dify: {
      baseUrl: data.DIFY_BASE_URL.replace(/\/+$/, ""),
      requestTimeoutMs: data.DIFY_REQUEST_TIMEOUT_MS,
    },
    webhook: {
      debounceMs: data.WEBHOOK_DEBOUNCE_MS,
    },
    handoff: {
      sharedSecret: data.HANDOFF_SHARED_SECRET,
      label: data.HANDOFF_LABEL,
    },
  };
}

/** Key in the `configs` table (middleware DB) for the manual Dify kill switch — issue #184. */
export const DIFY_KILL_SWITCH_KEY = "DIFY_KILL_SWITCH";

/**
 * Reads the manual Dify kill switch (issue #184) straight from Postgres — no
 * in-process cache, so a flip takes effect on the very next flush (the only
 * "latency" is one `SELECT` round-trip, observed <10ms against the local
 * Postgres container; there is no TTL to reduce because nothing here is
 * cached).
 *
 * Deliberately **fail-safe, not fail-closed**: this is the mirror image of
 * the #152 lesson (self-healing silently degrading when its config read
 * failed). The accident this function must never cause is silencing the bot.
 * So every ambiguous case — missing row, NULL, empty string, whitespace, any
 * value other than the exact literal `"true"` (case-insensitive, trimmed),
 * or a thrown DB error — resolves to `false` ("keep operating normally").
 * Only an explicit `"true"` turns the switch on.
 */
export async function isDifyKillSwitchEnabled(
  pool: import("pg").Pool,
  log?: { warn: (obj: unknown, msg?: string) => void },
): Promise<boolean> {
  try {
    const result = await pool.query("SELECT value FROM configs WHERE key = $1", [
      DIFY_KILL_SWITCH_KEY,
    ]);
    if (result.rows.length === 0) return false;
    const raw = result.rows[0].value;
    if (typeof raw !== "string") return false;
    return raw.trim().toLowerCase() === "true";
  } catch (err) {
    log?.warn(
      { err },
      "config: failed to read DIFY_KILL_SWITCH — defaulting to OFF (fail-safe: bot keeps answering, issue #184)",
    );
    return false;
  }
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
