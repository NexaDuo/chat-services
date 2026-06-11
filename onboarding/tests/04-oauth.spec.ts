import { test, expect } from '@playwright/test';
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
  };
  tenants: TenantConfig[];
}

const targetEnv = process.env.ENVIRONMENT || 'production';
const yamlPath = path.resolve(process.cwd(), '../tenants.yaml');
const fileContent = fs.readFileSync(yamlPath, 'utf8');
const config = yaml.parse(fileContent) as TenantsYaml;

const activeTenants = config.tenants.filter(t => t.status === 'active' && t.environment === targetEnv && t.infra?.chatwoot_url && t.infra?.dify_url);

test.describe(`Google OAuth init endpoints - Environment: ${targetEnv}`, () => {
  for (const tenant of activeTenants) {
    const chatwootUrl = tenant.infra!.chatwoot_url!;
    const difyUrl = tenant.infra!.dify_url!;

    test(`${tenant.name}: Chatwoot redirects to accounts.google.com`, async ({ browser }) => {
      const ctx = await browser.newContext();
      const page = await ctx.newPage();
      
      // Chatwoot v4 runs OmniAuth 2.x with omniauth-rails_csrf_protection,
      // which rejects a bare cross-site POST to the request phase (no
      // authenticity token) and bounces to /auth/sign_in. The provider also
      // allows GET (allowed_request_methods = [:post, :get]); a GET request is
      // not CSRF-validated and exercises the real request phase, so we probe
      // via GET — the same way the Dify check below works. The production flow
      // supports both methods.
      console.log(`Checking ${tenant.slug} Chatwoot OAuth at ${chatwootUrl}/auth/google_oauth2...`);
      const response = await page.goto(`${chatwootUrl}/auth/google_oauth2`);

      const finalUrl = page.url();
      const status = response?.status();
      const body = await response?.text() || '';

      expect(
        finalUrl,
        `Expected redirect chain to end at accounts.google.com but got ${finalUrl}. Body: ${body}`
      ).toMatch(/^https:\/\/accounts\.google\.com\//);
      expect(status).toBe(200);

      await ctx.close();
    });

    test(`${tenant.name}: Dify redirects to accounts.google.com`, async ({ browser }) => {
      const ctx = await browser.newContext();
      const page = await ctx.newPage();
      
      console.log(`Checking ${tenant.slug} Dify OAuth at ${difyUrl}/console/api/oauth/login/google...`);
      const response = await page.goto(`${difyUrl}/console/api/oauth/login/google`);
      
      const finalUrl = page.url();
      const res = await response;
      const status = res?.status();
      const body = await res?.text() || '';

      expect(status).toBe(200);
      expect(
        finalUrl,
        `Expected redirect chain to end at accounts.google.com but got ${finalUrl}. Body: ${body}`
      ).toMatch(/^https:\/\/accounts\.google\.com\//);

      await ctx.close();
    });
  }
});
