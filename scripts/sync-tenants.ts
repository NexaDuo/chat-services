import fs from 'fs';
import path from 'path';
import yaml from 'yaml';
import { Pool } from 'pg';
import { execSync } from 'child_process';
import dotenv from 'dotenv';
import crypto from 'crypto';

dotenv.config();

function maskSensitiveData(text: string): string {
  if (!text) return text;
  let masked = text;
  const dbUrl = process.env.DATABASE_URL;
  if (dbUrl && dbUrl.length > 5) {
    masked = masked.split(dbUrl).join('[DATABASE_URL_REDACTED]');
    try {
      const url = new URL(dbUrl);
      if (url.password) {
        masked = masked.split(url.password).join('[PASSWORD_REDACTED]');
      }
    } catch {
      // Not a valid URL
    }
  }
  return masked;
}

const logger = {
  log: (message: string) => {
    console.log(maskSensitiveData(message));
  },
  error: (message: string, error?: any) => {
    let output = maskSensitiveData(message);
    if (error) {
      const errorMsg = error.stack || error.message || String(error);
      output += `\n${maskSensitiveData(errorMsg)}`;
    }
    console.error(output);
  }
};

interface TenantConfig {
  slug: string;
  name: string;
  chatwoot_account_id: number;
  status: string;
  environment: string;
  infra?: {
    type: string;
    chatwoot_url?: string;
    dify_url?: string;
  };
}

interface TenantsYaml {
  global: {
    gcp_project_id: string;
    base_domain: string;
    admin?: {
      username: string;
      password: string;
    };
  };
  tenants: TenantConfig[];
}

async function syncDatabase(pool: Pool, tenants: TenantConfig[]) {
  logger.log('Syncing database...');
  for (const tenant of tenants) {
    const query = `
      INSERT INTO tenants (slug, subdomain, name, chatwoot_account_id, status, infra_type, chatwoot_url, dify_url)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
      ON CONFLICT (slug) DO UPDATE 
      SET subdomain = EXCLUDED.subdomain,
          name = EXCLUDED.name, 
          chatwoot_account_id = EXCLUDED.chatwoot_account_id,
          status = EXCLUDED.status,
          infra_type = EXCLUDED.infra_type,
          chatwoot_url = EXCLUDED.chatwoot_url,
          dify_url = EXCLUDED.dify_url,
          updated_at = CURRENT_TIMESTAMP;
    `;
    const values = [
      tenant.slug,
      tenant.slug,
      tenant.name, 
      tenant.chatwoot_account_id.toString(),
      tenant.status,
      tenant.infra?.type || 'shared',
      tenant.infra?.chatwoot_url || null,
      tenant.infra?.dify_url || null
    ];
    await pool.query(query, values);
    logger.log(`✅ Synced DB: ${tenant.slug}`);
  }
}

/** Quotes a value for inline SQL, or emits NULL. */
function sqlLiteral(value: string | null): string {
  if (value === null || value === undefined) return 'NULL';
  return `'${String(value).replace(/'/g, "''")}'`;
}

/**
 * Builds an idempotent seed script (same upsert as `syncDatabase`) for piping
 * straight into `psql`. Used by CI to seed the middleware DB through
 * `docker exec` on the VM, because Postgres is only reachable on the internal
 * docker network (`postgres:5432`) and is not published on the VM host.
 */
function buildSeedSql(tenants: TenantConfig[], admin?: { username: string; password: string }): string {
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
    ].map(sqlLiteral).join(', ');
    return `INSERT INTO tenants (slug, subdomain, name, chatwoot_account_id, status, infra_type, chatwoot_url, dify_url)
VALUES (${values})
ON CONFLICT (slug) DO UPDATE
SET subdomain = EXCLUDED.subdomain,
    name = EXCLUDED.name,
    chatwoot_account_id = EXCLUDED.chatwoot_account_id,
    status = EXCLUDED.status,
    infra_type = EXCLUDED.infra_type,
    chatwoot_url = EXCLUDED.chatwoot_url,
    dify_url = EXCLUDED.dify_url,
    updated_at = CURRENT_TIMESTAMP;`;
  });

  if (admin) {
    const pwdHash = crypto.createHash('sha256').update(admin.password).digest('hex');
    rows.push(`INSERT INTO users (username, password_hash, role)
VALUES ('${admin.username}', '${pwdHash}', 'admin')
ON CONFLICT (username)
DO UPDATE SET password_hash = EXCLUDED.password_hash, updated_at = CURRENT_TIMESTAMP;`);
  }

  return `BEGIN;\n${rows.join('\n')}\nCOMMIT;\n`;
}

function syncSecrets(projectId: string, tenants: TenantConfig[]) {
  logger.log(`Syncing GCP Secrets for project: ${projectId}...`);
  for (const tenant of tenants) {
    const secretName = `TENANT_${tenant.slug.toUpperCase().replace(/-/g, '_')}_API_KEY`;
    try {
      execSync(`gcloud secrets describe ${secretName} --project=${projectId}`, { stdio: 'ignore' });
      logger.log(`✅ Secret exists: ${secretName}`);
    } catch {
      logger.log(`Creating secret: ${secretName}...`);
      try {
        execSync(`gcloud secrets create ${secretName} --replication-policy="automatic" --project=${projectId}`, { stdio: 'ignore' });
        execSync(`gcloud secrets versions add ${secretName} --data-file=- --project=${projectId}`, {
          input: "placeholder-key",
          stdio: ['pipe', 'ignore', 'ignore']
        });
        logger.log(`✅ Created secret: ${secretName}`);
      } catch (err: any) {
        logger.error(`❌ Failed to create secret ${secretName}`, err);
      }
    }
  }
}

// The direct DB-sync path (local dev / non-CI) connects over TCP and can hit a
// transient `ECONNRESET`/`connection terminated` on a flaky link. Retry such
// failures rather than aborting (CI seeds via psql; see --print-sql).
const TRANSIENT_CODES = new Set([
  'ECONNRESET', 'ECONNREFUSED', 'ETIMEDOUT', 'EPIPE', 'ENETUNREACH',
  '57P01', '08006', '08003', '08001', // pg: admin shutdown / connection failures
]);

function isTransient(err: any): boolean {
  if (!err) return false;
  const code = err.code ?? err.errno;
  if (code && TRANSIENT_CODES.has(String(code))) return true;
  const msg = String(err.message || err).toLowerCase();
  return /econnreset|connection terminated|connection reset|timeout|server closed the connection|terminating connection/.test(msg);
}

async function withRetry<T>(label: string, attempts: number, fn: () => Promise<T>): Promise<T> {
  let lastErr: any;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      if (attempt === attempts || !isTransient(err)) throw err;
      const backoffMs = Math.min(1000 * 2 ** (attempt - 1), 8000);
      logger.error(`Transient error on ${label} (attempt ${attempt}/${attempts}); retrying in ${backoffMs}ms`, err);
      await new Promise((resolve) => setTimeout(resolve, backoffMs));
    }
  }
  throw lastErr;
}

function resolveAdmin(admin?: { username: string; password: string }, projectId?: string): { username: string; password: string } | undefined {
  if (!admin) return undefined;
  let username = admin.username;
  let password = admin.password;

  if (username.startsWith('gcp-secret:')) {
    const secretName = username.split(':')[1];
    try {
      if (!projectId) {
        throw new Error("GCP Project ID is required to resolve GCP secrets");
      }
      username = execSync(`gcloud secrets versions access latest --secret=${secretName} --project=${projectId}`).toString().trim();
    } catch (err) {
      if (process.env.ADMIN_EMAIL) {
        username = process.env.ADMIN_EMAIL;
      } else {
        logger.log(`⚠️ Failed to fetch secret ${secretName} from GCP (not authenticated/configured), falling back to 'admin'`);
        username = 'admin';
      }
    }
  }

  if (password.startsWith('gcp-secret:')) {
    const secretName = password.split(':')[1];
    try {
      if (!projectId) {
        throw new Error("GCP Project ID is required to resolve GCP secrets");
      }
      password = execSync(`gcloud secrets versions access latest --secret=${secretName} --project=${projectId}`).toString().trim();
    } catch (err) {
      if (process.env.ADMIN_PASSWORD) {
        password = process.env.ADMIN_PASSWORD;
      } else {
        logger.log(`⚠️ Failed to fetch secret ${secretName} from GCP (not authenticated/configured), falling back to 'AdminPass123!'`);
        password = 'AdminPass123!';
      }
    }
  }

  return { username, password };
}

async function main() {
  const yamlPath = path.resolve(process.cwd(), 'tenants.yaml');
  if (!fs.existsSync(yamlPath)) {
    logger.error(`Error: tenants.yaml not found at ${yamlPath}`);
    process.exit(1);
  }
  
  const fileContent = fs.readFileSync(yamlPath, 'utf8');
  const config = yaml.parse(fileContent) as TenantsYaml;

  // Resolve admin credentials if they use GCP Secret Manager
  let resolvedAdmin: { username: string; password: string } | undefined = undefined;
  if (config.global.admin) {
    try {
      resolvedAdmin = resolveAdmin(config.global.admin, config.global.gcp_project_id);
    } catch (err: any) {
      logger.error('Failed to resolve admin credentials from GCP Secret Manager:', err);
      process.exit(1);
    }
  }

  const args = process.argv.slice(2);
  const printSqlOnly = args.includes('--print-sql');
  const positional = args.filter((a) => !a.startsWith('--'));
  const targetEnv = positional[0] || process.env.ENVIRONMENT || 'production';

  const targetTenants = config.tenants.filter(t => (t.environment || 'production') === targetEnv);

  // --print-sql: emit an idempotent seed script to stdout and exit. CI pipes
  // this into `docker exec ... psql` on the VM (Postgres is docker-network-only,
  // not reachable over TCP from the runner). Keep stdout pure SQL.
  if (printSqlOnly) {
    if (targetTenants.length === 0) {
      process.stderr.write(`No tenants for environment ${targetEnv}; nothing to seed.\n`);
      return;
    }
    process.stdout.write(buildSeedSql(targetTenants, resolvedAdmin));
    return;
  }

  logger.log(`Target filtering environment: ${targetEnv}`);
  logger.log(`Found ${targetTenants.length} tenants for environment ${targetEnv}`);

  if (targetTenants.length === 0) {
    logger.log('No tenants to sync. Exiting successfully.');
    return;
  }

  // SKIP_DB_SYNC: CI seeds the DB out-of-band via psql (see --print-sql) and
  // uses this invocation only to reconcile GCP per-tenant secrets.
  const skipDbSync = process.env.SKIP_DB_SYNC === 'true';

  try {
    if (skipDbSync) {
      logger.log('SKIP_DB_SYNC=true; skipping database sync.');
    } else {
      const connectionString = process.env.DATABASE_URL;
      if (!connectionString) {
        logger.error('Error: DATABASE_URL environment variable is not set');
        process.exit(1);
      }
      // Recreate the pool on each attempt: a reset connection can leave the
      // pool unusable, and `SELECT 1` probes it before we start writing. The
      // sync is idempotent (ON CONFLICT DO UPDATE), so re-running is safe.
      await withRetry('database sync', 5, async () => {
        const pool = new Pool({ connectionString, connectionTimeoutMillis: 10000 });
        try {
          await pool.query('SELECT 1');
          await syncDatabase(pool, targetTenants);
        } finally {
          await pool.end();
        }
      });

      if (resolvedAdmin) {
        const { username, password } = resolvedAdmin;
        const pwdHash = crypto.createHash('sha256').update(password).digest('hex');
        await withRetry('admin user sync', 5, async () => {
          const pool = new Pool({ connectionString, connectionTimeoutMillis: 10000 });
          try {
            await pool.query(
              `INSERT INTO users (username, password_hash, role)
               VALUES ($1, $2, 'admin')
               ON CONFLICT (username)
               DO UPDATE SET password_hash = EXCLUDED.password_hash, updated_at = CURRENT_TIMESTAMP`,
              [username, pwdHash]
            );
            logger.log(`✅ Synced Admin User in DB: ${username}`);
          } finally {
            await pool.end();
          }
        });
      }
    }

    if (process.env.SKIP_GCP_SYNC === 'true') {
      logger.log('Skipping GCP Secrets sync as requested.');
    } else {
      syncSecrets(config.global.gcp_project_id, targetTenants);
    }
    logger.log('Tenant sync completed successfully.');
  } catch (error) {
    logger.error('Error during sync process:', error);
    process.exit(1);
  }
}

main().catch(err => {
  logger.error('Unhandled error:', err);
  process.exit(1);
});
