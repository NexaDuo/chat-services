import { test, expect } from '@playwright/test';
import fs from 'fs';
import path from 'path';
import yaml from 'yaml';
import dotenv from 'dotenv';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load .env from project root
dotenv.config({ path: path.resolve(__dirname, '../../.env'), quiet: true });

test.describe('Hybrid Tenant Resolution Verification', () => {
  let tenantsConfig: any;

  test.beforeAll(() => {
    const filePath = path.resolve(__dirname, '../../tenants.yaml');
    const fileContents = fs.readFileSync(filePath, 'utf8');
    tenantsConfig = yaml.parse(fileContents);
  });

  // Issue #292 / #275: two rows sharing chatwoot_account_id made tenant
  // resolution non-deterministic. One account => one active tenant.
  test('Each Chatwoot account maps to at most one active tenant in YAML', () => {
    const seen = new Map<string, string>();
    for (const tenant of tenantsConfig.tenants) {
      if (tenant.status !== 'active') continue;
      const account = String(tenant.chatwoot_account_id);
      expect(seen.get(account), `account ${account} active in both ${seen.get(account)} and ${tenant.slug}`).toBeUndefined();
      seen.set(account, tenant.slug);
    }
  });

  test('All tenants in YAML should resolve correctly via Middleware', async ({ request }) => {
    const middlewareUrl = process.env.MIDDLEWARE_URL || 'http://localhost:4000';
    const sharedSecret = process.env.HANDOFF_SHARED_SECRET;

    if (!sharedSecret) {
      console.warn('Warning: HANDOFF_SHARED_SECRET not set in environment. Test might fail if Middleware requires it.');
    }

    const targetEnv = process.env.ENVIRONMENT || 'production';
    console.log(`Using Middleware URL: ${middlewareUrl}`);
    console.log(`Filtering verification for environment: ${targetEnv}`);

    const targetTenants = tenantsConfig.tenants.filter((t: any) => (t.environment || 'production') === targetEnv);

    for (const tenant of targetTenants) {
      console.log(`Verifying tenant: ${tenant.slug}`);
      const response = await request.get(`${middlewareUrl}/resolve-tenant?subdomain=${tenant.slug}`, {
        headers: {
          Authorization: `Bearer ${sharedSecret}`
        }
      });
      
      if (response.status() !== 200) {
        const body = await response.text();
        console.error(`Failed to resolve tenant ${tenant.slug}. Status: ${response.status()}, Body: ${body}`);
      }
      
      expect(response.status()).toBe(200);
      const data = await response.json();
      
      expect(data.accountId).toBe(tenant.chatwoot_account_id.toString());
      
      if (tenant.infra?.type === 'dedicated') {
        expect(data.infraType).toBe('dedicated');
        expect(data.overrides.chatwootUrl).toBe(tenant.infra.chatwoot_url);
        expect(data.overrides.difyUrl).toBe(tenant.infra.dify_url);
      } else {
        expect(['shared', undefined]).toContain(data.infraType);
      }
    }
  });
});
