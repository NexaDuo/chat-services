import { z } from "zod";

/**
 * Tenant configuration for a single Chatwoot account.
 * Keyed by Chatwoot `account_id` (string) in `TENANT_MAP`.
 */
const TenantSchema = z.object({
  dify_api_key: z.string().min(1),
  dify_base_url: z.string().url().optional(),
});

export type Tenant = z.infer<typeof TenantSchema>;

const TenantMapSchema = z.record(z.string(), TenantSchema);

export type TenantMap = z.infer<typeof TenantMapSchema>;

function parseTenantMap(raw: string | undefined): TenantMap {
  if (!raw || raw.trim() === "" || raw.trim() === "{}") {
    return {};
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    throw new Error(
      `TENANT_MAP is not valid JSON. Expected a JSON object mapping account_id → { dify_api_key }. Got: ${(err as Error).message}`,
    );
  }
  const result = TenantMapSchema.safeParse(parsed);
  if (!result.success) {
    throw new Error(
      `TENANT_MAP schema mismatch: ${result.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; ")}`,
    );
  }
  return result.data;
}

const EnvSchema = z.object({
  PORT: z.coerce.number().int().positive().default(4000),
  LOG_LEVEL: z
    .enum(["trace", "debug", "info", "warn", "error", "fatal"])
    .default("info"),

  CHATWOOT_BASE_URL: z.string().url(),
  CHATWOOT_API_TOKEN: z.string().min(1, "CHATWOOT_API_TOKEN is required"),

  DIFY_BASE_URL: z.string().url(),
  DIFY_REQUEST_TIMEOUT_MS: z.coerce.number().int().positive().default(30000),

  TENANT_MAP: z.string().optional(),

  HANDOFF_SHARED_SECRET: z
    .string()
    .min(16, "HANDOFF_SHARED_SECRET must be at least 16 chars"),
  HANDOFF_LABEL: z.string().default("atendimento-humano"),
});

export type AppConfig = {
  port: number;
  logLevel: z.infer<typeof EnvSchema>["LOG_LEVEL"];
  chatwoot: {
    baseUrl: string;
    apiToken: string;
  };
  dify: {
    baseUrl: string;
    requestTimeoutMs: number;
  };
  tenants: TenantMap;
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
    chatwoot: {
      baseUrl: data.CHATWOOT_BASE_URL.replace(/\/+$/, ""),
      apiToken: data.CHATWOOT_API_TOKEN,
    },
    dify: {
      baseUrl: data.DIFY_BASE_URL.replace(/\/+$/, ""),
      requestTimeoutMs: data.DIFY_REQUEST_TIMEOUT_MS,
    },
    tenants: parseTenantMap(data.TENANT_MAP),
    handoff: {
      sharedSecret: data.HANDOFF_SHARED_SECRET,
      label: data.HANDOFF_LABEL,
    },
  };
}

/**
 * Resolves the per-tenant Dify config for a given Chatwoot account_id.
 * Returns `null` if the account is not mapped.
 */
export function resolveTenant(
  config: AppConfig,
  accountId: string | number,
): { apiKey: string; baseUrl: string } | null {
  const key = String(accountId);
  const tenant = config.tenants[key];
  if (!tenant) return null;
  return {
    apiKey: tenant.dify_api_key,
    baseUrl: (tenant.dify_base_url ?? config.dify.baseUrl).replace(/\/+$/, ""),
  };
}
