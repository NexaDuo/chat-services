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

// A bare hostname or IPv4 address: no scheme, port, path or userinfo.
const BrandingQuerySchema = z.object({
  host: z
    .string()
    .max(253)
    .regex(/^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/i),
});

/** The whole response of GET /public/tenant-branding. Nothing else may be added
 * without revisiting the fact that this route is unauthenticated. */
export interface TenantBranding {
  ogTitle: string | null;
  ogDescription: string | null;
  ogImageUrl: string | null;
}

interface OwnerRow {
  chatwoot_url: string | null;
  og_title: string | null;
  og_description: string | null;
  og_image_url: string | null;
}

const OWNERS_CACHE_MS = 60_000;

function hostnameOf(url: string | null): string | null {
  try {
    return url ? new URL(url).hostname.toLowerCase() : null;
  } catch {
    return null;
  }
}

function text(value: string | null): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}

/** og:image must be an absolute http(s) URL; anything else is dropped. */
function imageUrl(value: string | null): string | null {
  const trimmed = text(value);
  if (!trimmed || /[\s"'<>]/.test(trimmed)) return null;
  try {
    const url = new URL(trimmed);
    return url.protocol === "https:" || url.protocol === "http:" ? trimmed : null;
  } catch {
    return null;
  }
}

/**
 * Link-preview (Open Graph) branding of a Chatwoot host (issue #273), read by
 * deploy/open_graph.rb inside chatwoot-rails.
 *
 * Which tenant brands a host: the active tenant that holds Chatwoot account 1
 * on it, i.e. `status = 'active' AND chatwoot_account_id = '1'` and the host
 * of `chatwoot_url` equal to the requested host. This is the same "owner of
 * the installation" rule the admin routes use to find a parent tenant. Several
 * tenants share a host (one per Chatwoot account), but the root URL carries no
 * account, so only the owner can speak for it. Ties go to the oldest row.
 *
 * Deliberately unauthenticated: every field it returns is printed verbatim in
 * the public HTML of that host, so there is nothing to protect, and requiring
 * HANDOFF_SHARED_SECRET would mean handing chatwoot-rails a secret that also
 * opens /config and /resolve-tenant. In exchange the route is kept narrow:
 * the host is validated before any query, the response is exactly
 * `TenantBranding` (no slug, account id, URLs or keys), and the owner list is
 * cached for a minute so the route cannot be used to hammer Postgres.
 */
export async function registerTenantBrandingRoute(
  app: FastifyInstance,
  pool: pg.Pool,
): Promise<void> {
  let cached: { at: number; rows: OwnerRow[] } | null = null;

  async function owners(): Promise<OwnerRow[]> {
    if (cached && Date.now() - cached.at < OWNERS_CACHE_MS) return cached.rows;
    const result = await pool.query<OwnerRow>(
      `SELECT chatwoot_url, og_title, og_description, og_image_url
         FROM tenants
        WHERE status = 'active' AND chatwoot_account_id = '1' AND chatwoot_url IS NOT NULL
        ORDER BY created_at, slug`,
    );
    cached = { at: Date.now(), rows: result.rows };
    return result.rows;
  }

  app.get("/public/tenant-branding", async (request, reply) => {
    const parsed = BrandingQuerySchema.safeParse(request.query);
    if (!parsed.success) {
      return reply.code(400).send({ error: "invalid_query" });
    }
    const host = parsed.data.host.toLowerCase();

    let rows: OwnerRow[];
    try {
      rows = await owners();
    } catch (err) {
      app.log.error({ err }, "Failed to fetch tenant branding from database");
      return reply.code(503).send({ error: "unavailable" });
    }

    const row = rows.find((candidate) => hostnameOf(candidate.chatwoot_url) === host);
    if (!row) {
      return reply.code(404).send({ error: "tenant_not_found" });
    }

    const branding: TenantBranding = {
      ogTitle: text(row.og_title),
      ogDescription: text(row.og_description),
      ogImageUrl: imageUrl(row.og_image_url),
    };
    return reply.code(200).header("cache-control", "public, max-age=60").send(branding);
  });
}
