import fs from 'fs';
import path from 'path';
import yaml from 'yaml';
import { Pool } from 'pg';
import { execSync } from 'child_process';
import dotenv from 'dotenv';

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

async function main() {
  const yamlPath = path.resolve(process.cwd(), 'tenants.yaml');
  if (!fs.existsSync(yamlPath)) {
    logger.error(`Error: tenants.yaml not found at ${yamlPath}`);
    process.exit(1);
  }
  
  const fileContent = fs.readFileSync(yamlPath, 'utf8');
  const config = yaml.parse(fileContent) as TenantsYaml;
  
  const targetEnv = process.argv[2] || process.env.ENVIRONMENT || 'production';
  logger.log(`Target filtering environment: ${targetEnv}`);

  const targetTenants = config.tenants.filter(t => (t.environment || 'production') === targetEnv);
  logger.log(`Found ${targetTenants.length} tenants for environment ${targetEnv}`);

  if (targetTenants.length === 0) {
    logger.log('No tenants to sync. Exiting successfully.');
    return;
  }

  const connectionString = process.env.DATABASE_URL;
  if (!connectionString) {
    logger.error('Error: DATABASE_URL environment variable is not set');
    process.exit(1);
  }

  const pool = new Pool({ connectionString });
  
  try {
    await syncDatabase(pool, targetTenants);
    if (process.env.SKIP_GCP_SYNC === 'true') {
      logger.log('Skipping GCP Secrets sync as requested.');
    } else {
      syncSecrets(config.global.gcp_project_id, targetTenants);
    }
    logger.log('Tenant sync completed successfully.');
  } catch (error) {
    logger.error('Error during sync process:', error);
    process.exit(1);
  } finally {
    await pool.end();
  }
}

main().catch(err => {
  logger.error('Unhandled error:', err);
  process.exit(1);
});
