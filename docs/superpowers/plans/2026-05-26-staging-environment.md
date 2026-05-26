# Staging Environment Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish staging environment support by updating tenants.yaml schema with environment-specific tenants, and updating sync-tenants.ts to filter and sync by environment.

**Architecture:** The tenants.yaml file is updated to contain environment-specific configurations. The sync-tenants.ts script is refactored to filter tenants based on a target environment parameter and safely push configuration updates to the appropriate target database.

**Tech Stack:** Node.js, TypeScript, PostgreSQL, YAML

---

### Task 1: Update tenants.yaml Schema and Add Validation

**Files:**
- Create: `scripts/validate-schema.ts`
- Modify: `tenants.yaml`
- Test: `scripts/validate-schema.ts`

- [ ] **Step 1: Write the schema validation test**

Create `scripts/validate-schema.ts` to enforce the new `tenants.yaml` format:

```typescript
import fs from 'fs';
import path from 'path';
import yaml from 'yaml';

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
    default_chatwoot_url?: string;
    default_dify_url?: string;
  };
  tenants: TenantConfig[];
}

function validate() {
  const yamlPath = path.resolve(process.cwd(), 'tenants.yaml');
  const fileContent = fs.readFileSync(yamlPath, 'utf8');
  const config = yaml.parse(fileContent) as TenantsYaml;

  if (!config.global.gcp_project_id || !config.global.base_domain) {
    throw new Error('Global project_id or base_domain missing');
  }

  if (config.global.default_chatwoot_url || config.global.default_dify_url) {
    throw new Error('Deprecated global default URLs must be removed');
  }

  for (const tenant of config.tenants) {
    if (!tenant.environment) {
      throw new Error(`Tenant ${tenant.slug} missing environment field`);
    }
    if (!['production', 'staging'].includes(tenant.environment)) {
      throw new Error(`Tenant ${tenant.slug} has invalid environment: ${tenant.environment}`);
    }
    if (!tenant.infra || !tenant.infra.chatwoot_url || !tenant.infra.dify_url) {
      throw new Error(`Tenant ${tenant.slug} missing explicit infra URLs`);
    }
  }
  console.log('✅ tenants.yaml schema validation passed');
}

validate();
```

- [ ] **Step 2: Run verification test to ensure failure**

Run: `npx tsx scripts/validate-schema.ts`
Expected Output: Fail with error: `Deprecated global default URLs must be removed` or `Tenant missing environment field`.

- [ ] **Step 3: Update tenants.yaml schema and entries**

Rewrite `tenants.yaml` to comply with the updated design:

```yaml
# tenants.yaml
global:
  gcp_project_id: "nexaduo-492818"
  base_domain: "nexaduo.com"

tenants:
  - slug: nexaduo
    name: NexaDuo Main
    chatwoot_account_id: 1
    status: active
    environment: production
    infra:
      type: shared
      chatwoot_url: "https://chat.nexaduo.com"
      dify_url: "https://dify.nexaduo.com"

  - slug: acme-dedicated
    name: Acme Dedicated
    chatwoot_account_id: 1
    status: onboarding
    environment: production
    infra:
      type: dedicated
      chatwoot_url: "https://chat.acme.com"
      dify_url: "https://dify.acme.com"

  - slug: acme-stg
    name: Acme Staging Tenant
    chatwoot_account_id: 1
    status: active
    environment: staging
    infra:
      type: shared
      chatwoot_url: "https://chat-stg.nexaduo.com"
      dify_url: "https://dify-stg.nexaduo.com"
```

- [ ] **Step 4: Run verification test to ensure success**

Run: `npx tsx scripts/validate-schema.ts`
Expected Output: `✅ tenants.yaml schema validation passed`

- [ ] **Step 5: Commit changes**

```bash
git add tenants.yaml scripts/validate-schema.ts
git commit -m "feat: add schema validation and update tenants.yaml format"
```

---

### Task 2: Update sync-tenants.ts to Support Environment Filtering

**Files:**
- Modify: `scripts/sync-tenants.ts`
- Test: `npm run typecheck`

- [ ] **Step 1: Write a type check test block**

Temporarily add an invalid config parameter to the sync code to verify build fails:

```typescript
// Add to top level of scripts/sync-tenants.ts
const dummyTest: TenantsYaml = {
  global: {
    gcp_project_id: "test",
    base_domain: "test",
    default_chatwoot_url: "test" // Should fail compile once types are updated
  },
  tenants: []
};
```

Run: `npm run typecheck`
Expected Output: Compile error or type incompatibility.

- [ ] **Step 2: Update script code with filtering and updated types**

Replace `scripts/sync-tenants.ts` with updated types, explicit URL mappings, and target filtering:

```typescript
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
```

- [ ] **Step 3: Run typecheck to verify success**

Run: `npm run typecheck`
Expected Output: No compile errors.

- [ ] **Step 4: Commit changes**

```bash
git add scripts/sync-tenants.ts
git commit -m "feat: implement environment filtering and explicit url mapping in sync script"
```
