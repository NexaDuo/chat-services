# Centralized Tenant Management Implementation Plan (Hybrid Infra Support)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Centralize tenant configuration into a single `tenants.yaml` file, supporting both shared and dedicated infrastructure, and automate synchronization to the Middleware database and GCP Secret Manager.

**Architecture:** A root `tenants.yaml` serves as the source of truth. A synchronization script (`scripts/sync-tenants.ts`) parses the YAML, idempotently updates the `tenants` table in Postgres (including infrastructure overrides), and ensures tenant-specific secrets exist in GCP Secret Manager.

**Tech Stack:** Node.js, TypeScript, YAML, pg (Postgres), @google-cloud/secret-manager (via gcloud CLI), Playwright.

---

### Task 1: Update `tenants.yaml` and Database Schema

**Files:**
- Create/Modify: `tenants.yaml`
- Modify: `infrastructure/terraform/envs/production/tenant/main.tf` (or manual migration script)

- [ ] **Step 1: Define the hybrid `tenants.yaml`**

```yaml
# tenants.yaml
global:
  gcp_project_id: "nexaduo-492818"
  base_domain: "nexaduo.com"
  default_chatwoot_url: "https://chat.nexaduo.com"
  default_dify_url: "https://dify.nexaduo.com"

tenants:
  - slug: nexaduo
    name: NexaDuo Main
    chatwoot_account_id: 1
    status: active
    # uses defaults

  - slug: acme-dedicated
    name: Acme Dedicated
    chatwoot_account_id: 1
    status: onboarding
    infra:
      type: dedicated
      chatwoot_url: "https://chat.acme.com"
      dify_url: "https://dify.acme.com"
```

- [ ] **Step 2: Prepare SQL Migration for `tenants` table**
We need to add columns to support infrastructure overrides.

```sql
ALTER TABLE tenants 
ADD COLUMN IF NOT EXISTS infra_type TEXT DEFAULT 'shared',
ADD COLUMN IF NOT EXISTS chatwoot_url TEXT,
ADD COLUMN IF NOT EXISTS dify_url TEXT;
```

- [ ] **Step 3: Commit**

```bash
git add tenants.yaml
git commit -m "feat(tenants): define hybrid yaml structure and prepared schema updates"
```

### Task 2: Implement Multi-tenant Sync Script (DB + GCP)

**Files:**
- Create: `scripts/sync-tenants.ts`

- [ ] **Step 1: Implement the Sync Script with Hybrid Logic**

```typescript
import fs from 'fs';
import path from 'path';
import yaml from 'yaml';
import { Pool } from 'pg';
import { execSync } from 'child_process';

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
  for (const tenant of tenants) {
    const query = `
      INSERT INTO tenants (slug, name, chatwoot_account_id, status, infra_type, chatwoot_url, dify_url)
      VALUES ($1, $2, $3, $4, $5, $6, $7)
      ON CONFLICT (slug) DO UPDATE 
      SET name = EXCLUDED.name, 
          chatwoot_account_id = EXCLUDED.chatwoot_account_id,
          status = EXCLUDED.status,
          infra_type = EXCLUDED.infra_type,
          chatwoot_url = EXCLUDED.chatwoot_url,
          dify_url = EXCLUDED.dify_url,
          updated_at = CURRENT_TIMESTAMP;
    `;
    const values = [
      tenant.slug, 
      tenant.name, 
      tenant.chatwoot_account_id, 
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
  for (const tenant of tenants) {
    const secretName = `TENANT_${tenant.slug.toUpperCase().replace(/-/g, '_')}_API_KEY`;
    try {
      execSync(`gcloud secrets describe ${secretName} --project=${projectId}`, { stdio: 'ignore' });
      console.log(`✅ Secret exists: ${secretName}`);
    } catch {
      console.log(`Creating secret: ${secretName}...`);
      execSync(`gcloud secrets create ${secretName} --replication-policy="automatic" --project=${projectId}`);
      execSync(`echo -n "placeholder-key" | gcloud secrets versions add ${secretName} --data-file=- --project=${projectId}`);
    }
  }
}

async function main() {
  const config = yaml.parse(fs.readFileSync('tenants.yaml', 'utf8')) as TenantsYaml;
  const pool = new Pool({ connectionString: process.env.DATABASE_URL });
  
  await syncDatabase(pool, config.tenants);
  syncSecrets(config.global.gcp_project_id, config.tenants);
  
  await pool.end();
}

main().catch(console.error);
```

- [ ] **Step 2: Commit**

```bash
git add scripts/sync-tenants.ts
git commit -m "feat(tenants): hybrid sync script for DB and GCP secrets"
```

### Task 3: Update Middleware Resolver for Hybrid Routing

**Files:**
- Modify: `middleware/src/handlers/tenant.ts`

- [ ] **Step 1: Return infra overrides in `/resolve-tenant`**

```typescript
// Update the SELECT query in middleware/src/handlers/tenant.ts
const result = await pool.query(
  "SELECT chatwoot_account_id, infra_type, chatwoot_url, dify_url FROM tenants WHERE subdomain = $1",
  [subdomain]
);

// Return the enriched data
return reply.code(200).send({
  subdomain,
  accountId: result.rows[0].chatwoot_account_id,
  infraType: result.rows[0].infra_type,
  overrides: {
    chatwootUrl: result.rows[0].chatwoot_url,
    difyUrl: result.rows[0].dify_url
  }
});
```

- [ ] **Step 2: Commit**

```bash
git add middleware/src/handlers/tenant.ts
git commit -m "feat(middleware): include infra overrides in tenant resolution"
```

### Task 4: Update Cloudflare Worker for Dynamic Routing

**Files:**
- Modify: `edge/cloudflare-worker/src/index.ts`

- [ ] **Step 1: Update routing logic to use Middleware overrides**

```typescript
// In resolveTenant function, update response handling:
const data = await response.json() as { 
  accountId: string, 
  overrides?: { chatwootUrl?: string, difyUrl?: string } 
};

// In the main handler, use overrides if present:
let originHostname = env.CHAT_ORIGIN;
if (hostname.includes('dify')) {
  originHostname = data.overrides?.difyUrl ? new URL(data.overrides.difyUrl).hostname : env.DIFY_ORIGIN;
} else if (data.overrides?.chatwootUrl) {
  originHostname = new URL(data.overrides.chatwootUrl).hostname;
}
```

- [ ] **Step 2: Commit**

```bash
git add edge/cloudflare-worker/src/index.ts
git commit -m "feat(worker): support dynamic routing based on tenant overrides"
```

### Task 5: End-to-End Validation

**Files:**
- Create: `onboarding/tests/07-hybrid-tenants.spec.ts`

- [ ] **Step 1: Verify shared and dedicated resolution**

```typescript
// Add tests to verify that 'nexaduo' resolves to default origin 
// and 'acme-dedicated' resolves to its specific origin.
```

- [ ] **Step 2: Commit**

```bash
git add onboarding/tests/07-hybrid-tenants.spec.ts
git commit -m "test(tenants): verify hybrid routing resolution"
```
