import { test, expect } from '@playwright/test';
import fs from 'fs';
import path from 'path';
import yaml from 'yaml';
import dotenv from 'dotenv';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load .env from project root
dotenv.config({ path: path.resolve(__dirname, '../../.env') });

test.describe('Hybrid Tenant Resolution Verification', () => {
  let tenantsConfig: any;

  test.beforeAll(() => {
    const filePath = path.resolve(__dirname, '../../tenants.yaml');
    const fileContents = fs.readFileSync(filePath, 'utf8');
    tenantsConfig = yaml.parse(fileContents);
  });

  test('All tenants in YAML should resolve correctly via Middleware', async ({ request }) => {
    const middlewareUrl = process.env.MIDDLEWARE_URL || 'http://localhost:4000';
    const sharedSecret = process.env.HANDOFF_SHARED_SECRET;

    if (!sharedSecret) {
      console.warn('Warning: HANDOFF_SHARED_SECRET not set in environment. Test might fail if Middleware requires it.');
    }

    console.log(`Using Middleware URL: ${middlewareUrl}`);

    for (const tenant of tenantsConfig.tenants) {
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
        expect(data.infraType).toBe('shared' || undefined); // MiddleWare might return 'shared'
      }
    }
  });
});
