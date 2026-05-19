import fs from 'fs';
import path from 'path';
import yaml from 'yaml';
import { Pool } from 'pg';
import { execSync } from 'child_process';
import dotenv from 'dotenv';

dotenv.config();

interface TenantConfig {
  slug: string;
  name: string;
  chatwoot_account_id: number;
  status: string;
  infra?: {
    type: string;
    chatwoot_url?: string;
    dify_url?: string;
  };
}

interface TenantsYaml {
  global: {
    gcp_project_id: string;
    default_chatwoot_url: string;
    default_dify_url: string;
  };
  tenants: TenantConfig[];
}

async function syncDatabase(pool: Pool, tenants: TenantConfig[]) {
  console.log('Syncing database...');
  for (const tenant of tenants) {
    // Note: 'subdomain' is required in the schema (middleware database)
    // We use 'slug' as the 'subdomain' as it is the primary identifier.
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
      tenant.slug, // Using slug as subdomain
      tenant.name, 
      tenant.chatwoot_account_id.toString(), // Cast to TEXT for the schema
      tenant.status,
      tenant.infra?.type || 'shared',
      tenant.infra?.chatwoot_url || null,
      tenant.infra?.dify_url || null
    ];
    await pool.query(query, values);
    console.log(`✅ Synced DB: ${tenant.slug}`);
  }
}

function syncSecrets(projectId: string, tenants: TenantConfig[]) {
  console.log(`Syncing GCP Secrets for project: ${projectId}...`);
  for (const tenant of tenants) {
    const secretName = `TENANT_${tenant.slug.toUpperCase().replace(/-/g, '_')}_API_KEY`;
    try {
      execSync(`gcloud secrets describe ${secretName} --project=${projectId}`, { stdio: 'ignore' });
      console.log(`✅ Secret exists: ${secretName}`);
    } catch {
      console.log(`Creating secret: ${secretName}...`);
      try {
        execSync(`gcloud secrets create ${secretName} --replication-policy="automatic" --project=${projectId}`);
        // Add a placeholder version
        execSync(`echo -n "placeholder-key" | gcloud secrets versions add ${secretName} --data-file=- --project=${projectId}`);
        console.log(`✅ Created secret: ${secretName}`);
      } catch (err: any) {
        console.error(`❌ Failed to create secret ${secretName}: ${err.message}`);
      }
    }
  }
}

async function main() {
  const yamlPath = path.resolve(process.cwd(), 'tenants.yaml');
  if (!fs.existsSync(yamlPath)) {
    console.error(`Error: tenants.yaml not found at ${yamlPath}`);
    process.exit(1);
  }
  
  const fileContent = fs.readFileSync(yamlPath, 'utf8');
  const config = yaml.parse(fileContent) as TenantsYaml;
  
  const connectionString = process.env.DATABASE_URL;
  if (!connectionString) {
    console.error('Error: DATABASE_URL environment variable is not set');
    process.exit(1);
  }

  const pool = new Pool({ connectionString });
  
  try {
    await syncDatabase(pool, config.tenants);
    syncSecrets(config.global.gcp_project_id, config.tenants);
    console.log('Tenant sync completed successfully.');
  } catch (error) {
    console.error('Error during sync process:', error);
    process.exit(1);
  } finally {
    await pool.end();
  }
}

main().catch(err => {
  console.error('Unhandled error:', err);
  process.exit(1);
});
