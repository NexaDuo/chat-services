import crypto from 'crypto';

export interface TenantConfig {
  slug: string;
  name: string;
  chatwoot_account_id: number;
  status: string;
  environment: string;
  infra?: {
    type: string;
    chatwoot_url?: string;
    dify_url?: string;
    dify_app_type?: string;
    // May be a literal key or a `gcp-secret:<name>` reference, resolved by
    // `resolveTenantSecrets` before seeding.
    dify_api_key?: string;
  };
}

/**
 * One Chatwoot account must map to exactly one ACTIVE tenant (issue #292).
 * Mirrors the partial unique index `uq_tenants_active_chatwoot_account` in
 * infrastructure/postgres/01-init.sql, but fails early with a readable error
 * instead of a mid-transaction constraint violation. Also rejects duplicate
 * slugs, which the `ON CONFLICT (slug)` upsert would silently collapse.
 */
export function assertUniqueActiveAccounts(tenants: TenantConfig[]): void {
  const problems: string[] = [];
  const seenSlugs = new Set<string>();
  const activeByAccount = new Map<string, string[]>();
  for (const t of tenants) {
    if (seenSlugs.has(t.slug)) problems.push(`duplicate slug "${t.slug}"`);
    seenSlugs.add(t.slug);
    if (t.status === 'active') {
      const key = String(t.chatwoot_account_id);
      activeByAccount.set(key, [...(activeByAccount.get(key) ?? []), t.slug]);
    }
  }
  for (const [account, slugs] of activeByAccount) {
    if (slugs.length > 1) {
      problems.push(
        `chatwoot_account_id ${account} has ${slugs.length} active tenants (${slugs.join(', ')}); only one tenant may be active per Chatwoot account`,
      );
    }
  }
  if (problems.length > 0) {
    throw new Error(`Invalid tenants.yaml: ${problems.join('; ')}`);
  }
}

/** Quotes a value for inline SQL, or emits NULL. */
export function sqlLiteral(value: string | null): string {
  if (value === null || value === undefined) return 'NULL';
  return `'${String(value).replace(/'/g, "''")}'`;
}

/**
 * Builds an idempotent seed script (same upsert as `syncDatabase`) for piping
 * straight into `psql`. Used by CI to seed the middleware DB through
 * `docker exec` on the VM, because Postgres is only reachable on the internal
 * docker network (`postgres:5432`) and is not published on the VM host.
 */
export function buildSeedSql(tenants: TenantConfig[], admin?: { username: string; password: string }): string {
  assertUniqueActiveAccounts(tenants);
  const rows = tenants.map((tenant) => {
    const values = [
      tenant.slug,
      tenant.slug,
      tenant.name,
      tenant.chatwoot_account_id.toString(),
      tenant.status,
      tenant.infra?.type || 'shared',
      tenant.infra?.chatwoot_url || null,
      tenant.infra?.dify_url || null,
      tenant.infra?.dify_app_type || 'chatflow',
      tenant.infra?.dify_api_key || null,
    ].map(sqlLiteral).join(', ');
    return `INSERT INTO tenants (slug, subdomain, name, chatwoot_account_id, status, infra_type, chatwoot_url, dify_url, dify_app_type, dify_api_key)
VALUES (${values})
ON CONFLICT (slug) DO UPDATE
SET subdomain = EXCLUDED.subdomain,
    name = EXCLUDED.name,
    chatwoot_account_id = EXCLUDED.chatwoot_account_id,
    status = EXCLUDED.status,
    infra_type = EXCLUDED.infra_type,
    chatwoot_url = EXCLUDED.chatwoot_url,
    dify_url = EXCLUDED.dify_url,
    dify_app_type = EXCLUDED.dify_app_type,
    dify_api_key = COALESCE(EXCLUDED.dify_api_key, tenants.dify_api_key),
    updated_at = CURRENT_TIMESTAMP;`;
  });

  if (admin) {
    const pwdHash = crypto.createHash('sha256').update(admin.password).digest('hex');
    rows.push(`INSERT INTO users (username, password_hash, role)
VALUES (${sqlLiteral(admin.username)}, '${pwdHash}', 'admin')
ON CONFLICT (username)
DO UPDATE SET password_hash = EXCLUDED.password_hash, updated_at = CURRENT_TIMESTAMP;`);
  }

  return `BEGIN;\n${rows.join('\n')}\nCOMMIT;\n`;
}
