import { test, expect } from '@playwright/test';
import Fastify, { FastifyInstance } from 'fastify';
import { registerAdminRoutes } from '../../middleware/src/handlers/admin.js';
import dotenv from 'dotenv';
import path from 'path';
import fs from 'fs';
import yaml from 'yaml';
import pg from 'pg';
import crypto from 'crypto';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load .env from project root
dotenv.config({ path: path.resolve(__dirname, '../../.env') });

const liveMiddlewareUrl = process.env.MIDDLEWARE_URL;
const testMiddlewareUrl = 'http://127.0.0.1:4000';

const targetMiddlewareUrl = liveMiddlewareUrl || testMiddlewareUrl;
const targetUsername = process.env.ADMIN_EMAIL || 'admin';
const targetPassword = liveMiddlewareUrl
  ? (process.env.ADMIN_PASSWORD || process.env.HANDOFF_SHARED_SECRET || 'test-admin-password')
  : 'test-admin-password';

// Load tenants.yaml to find a valid tenant slug for live testing
let liveTenantSlug = 'nexaduo'; // fallback default
try {
  const yamlPath = path.resolve(__dirname, '../../tenants.yaml');
  if (fs.existsSync(yamlPath)) {
    const fileContents = fs.readFileSync(yamlPath, 'utf8');
    const config = yaml.parse(fileContents);
    const env = process.env.ENVIRONMENT || 'production';
    const envTenants = config.tenants.filter((t: any) => (t.environment || 'production') === env);
    if (envTenants.length > 0) {
      liveTenantSlug = envTenants[0].slug;
    }
  }
} catch (e) {
  // Ignore
}

const targetTenantSlug = liveMiddlewareUrl ? liveTenantSlug : 'nexaduo';

let server: FastifyInstance;

// Mock database pool for the test Fastify server
const mockDb = {
  queries: [] as { text: string; values: any[] }[],
  query: async (text: string, values?: any[]) => {
    mockDb.queries.push({ text, values: values || [] });
    
    if (text.includes("FROM users WHERE username =")) {
      const hash = crypto.createHash('sha256').update(targetPassword).digest('hex');
      return {
        rows: [
          { id: 1, password_hash: hash, role: 'admin' }
        ]
      };
    }
    
    if (text.includes("JOIN users u ON s.user_id = u.id")) {
      return {
        rows: [
          { username: targetUsername, role: 'admin' }
        ]
      };
    }

    if (text.includes("INSERT INTO sessions") || text.includes("DELETE FROM sessions")) {
      return { rows: [] };
    }

    // GET /admin/api/tenants
    if (text.includes("DISTINCT ON (slug)")) {
      return {
        rows: [
          {
            slug: 'nexaduo',
            name: 'NexaDuo Main',
            chatwoot_url: 'https://chat.nexaduo.com',
            dify_url: 'https://dify.nexaduo.com'
          },
          {
            slug: 'acme-dedicated',
            name: 'Acme Dedicated',
            chatwoot_url: 'https://chat.acme.com',
            dify_url: 'https://dify.acme.com'
          }
        ]
      };
    }
    
    // Resolve parent URLs
    if (text.includes("LIMIT 1") && text.includes("chatwoot_account_id = '1'")) {
      const slug = values ? values[0] : '';
      if (slug === 'nexaduo') {
        return {
          rows: [{ chatwoot_url: 'https://chat.nexaduo.com', dify_url: 'https://dify.nexaduo.com' }]
        };
      }
      return { rows: [] };
    }
    
    // GET client accounts under tenant
    if (text.includes("chatwoot_account_id != '1'")) {
      return {
        rows: [
          {
            slug: 'miau-duda',
            subdomain: 'duda',
            name: 'Miau Duda',
            chatwoot_account_id: '12',
            status: 'active',
            dify_app_type: 'chatflow'
          }
        ]
      };
    }

    // GET /admin/api/accounts (Dify routing config screen)
    if (text.includes("FROM tenants") && text.includes("ORDER BY chatwoot_account_id")) {
      return {
        rows: [
          { slug: 'duda', subdomain: 'duda', name: 'Miau Duda', chatwoot_account_id: '12', status: 'active', dify_app_type: 'agent', chatwoot_url: 'https://chat.nexaduo.com', dify_url: 'https://dify.nexaduo.com', dify_api_key: 'app-duda-key' },
          { slug: 'nexaduo', subdomain: 'nexaduo', name: 'NexaDuo Main', chatwoot_account_id: '1', status: 'active', dify_app_type: 'chatflow', chatwoot_url: 'https://chat.nexaduo.com', dify_url: 'https://dify.nexaduo.com', dify_api_key: null }
        ]
      };
    }

    // PUT /admin/api/accounts/:slug/dify
    if (text.includes("UPDATE tenants")) {
      const slug = values ? values[values.length - 1] : '';
      return { rowCount: slug === 'ghost' ? 0 : 1, rows: [] };
    }

    // Mapped tenants query for discovery
    if (text.includes("FROM tenants WHERE chatwoot_url = $1")) {
      return {
        rows: [
          {
            subdomain: 'duda',
            chatwoot_account_id: '12',
            dify_api_key: 'app-dify-api-key-1'
          }
        ]
      };
    }
    
    // Dify database query
    if (text.includes("FROM apps") || text.includes("FROM app")) {
      return {
        rows: [
          {
            id: 'dify-app-1',
            name: 'Acme AI Assistant',
            mode: 'agent-chat',
            api_key: 'app-dify-api-key-1'
          },
          {
            id: 'dify-app-2',
            name: 'Unmapped Dify Bot',
            mode: 'chat',
            api_key: 'app-dify-api-key-2'
          }
        ]
      };
    }

    return { rows: [] };
  }
};

// Mock Axios calls for the local test server
const mockAxiosRequests: any[] = [];
const mockAxios = {
  post: async (url: string, data?: any, config?: any) => {
    mockAxiosRequests.push({ method: 'POST', url, data, headers: config?.headers });
    if (url.includes('/platform/api/v1/accounts')) {
      if (url.includes('/account_users')) {
        return { data: { status: 'success' } };
      }
      return { data: { id: 456 } };
    }
    if (url.includes('/platform/api/v1/users')) {
      return { data: { id: 789, access_token: 'mock-user-token' } };
    }
    if (url.includes('/instance/create') || url.includes('/chatwoot/set')) {
      return { data: { status: 'SUCCESS' } };
    }
    return { data: {} };
  },
  get: async (url: string, config?: any) => {
    mockAxiosRequests.push({ method: 'GET', url, headers: config?.headers });
    if (url.includes('/instance/connectionState')) {
      return { data: { instance: { state: 'open' } } };
    }
    if (url.includes('/platform/api/v1/accounts')) {
      return {
        data: [
          { id: 1, name: "Admin Principal" },
          { id: 12, name: "Miau Duda" },
          { id: 99, name: "Some Unmapped Account" }
        ]
      };
    }
    if (url.includes('/instance/fetchInstances')) {
      return {
        data: [
          { name: "duda-instagram", status: "connected" },
          { name: "orphan-instagram", status: "disconnected" }
        ]
      };
    }
    return { data: {} };
  },
  delete: async (url: string, config?: any) => {
    mockAxiosRequests.push({ method: 'DELETE', url, headers: config?.headers });
    return { data: { status: 'success' } };
  }
};

test.beforeAll(async () => {
  pg.Pool = class MockPool {
    constructor() {}
    async query(text: string, values?: any[]) {
      if (text.includes("FROM apps") || text.includes("FROM app")) {
        return {
          rows: [
            {
              id: 'dify-app-1',
              name: 'Acme AI Assistant',
              mode: 'agent-chat',
              api_key: 'app-dify-api-key-1'
            },
            {
              id: 'dify-app-2',
              name: 'Unmapped Dify Bot',
              mode: 'chat',
              api_key: 'app-dify-api-key-2'
            }
          ]
        };
      }
      return { rows: [] };
    }
    async end() {}
  } as any;

  server = Fastify({
    logger: false
  });
  
  const mockConfig = {
    adminPassword: 'test-admin-password',
    databaseUrl: 'postgresql://postgres:pass@localhost:5432/middleware',
    handoff: {
      sharedSecret: 'test-secret'
    },
    evolution: {
      apiKey: 'test-evo-key',
      baseUrl: 'http://evolution-api:8080'
    },
    chatwoot: {
      baseUrl: 'https://chat.nexaduo.com',
      apiToken: 'test-cw-token',
      platformToken: 'test-platform-token'
    }
  };
  
  await registerAdminRoutes(server, mockConfig as any, mockDb as any, mockAxios);
  await server.listen({ port: 4000, host: '127.0.0.1' });
});

test.afterAll(async () => {
  await server.close();
});

async function getSessionCookie(request: any): Promise<string> {
  const response = await request.post(`${targetMiddlewareUrl}/admin/api/login`, {
    data: {
      username: targetUsername,
      password: targetPassword
    }
  });
  expect(response.status()).toBe(200);
  const headers = response.headers();
  const setCookie = headers['set-cookie'] || '';
  const match = setCookie.match(/admin_session=([^;]+)/);
  if (!match) {
    throw new Error('Failed to retrieve admin_session cookie from Set-Cookie header');
  }
  return match[1];
}

test.describe('Omnichannel Admin Portal Authentication', () => {
  test('should return 302 redirect when accessing /admin without session cookie', async ({ request }) => {
    const response = await request.get(`${targetMiddlewareUrl}/admin`, {
      maxRedirects: 0
    });
    expect(response.status()).toBe(302);
    expect(response.headers().location).toBe('/admin/login');
  });

  test('should return 401 when accessing API route without session cookie', async ({ request }) => {
    const response = await request.get(`${targetMiddlewareUrl}/admin/api/tenants`);
    expect(response.status()).toBe(401);
  });

  test('should return 200 when accessing /admin with correct session cookie', async ({ request }) => {
    const token = await getSessionCookie(request);
    const response = await request.get(`${targetMiddlewareUrl}/admin`, {
      headers: { cookie: `admin_session=${token}` }
    });
    expect(response.status()).toBe(200);
    const body = await response.text();
    expect(body).toContain('Omnichannel Admin Portal');
  });

  test('should return 401 on login with invalid credentials', async ({ request }) => {
    const response = await request.post(`${targetMiddlewareUrl}/admin/api/login`, {
      data: {
        username: 'wrong-user',
        password: 'wrong-password'
      }
    });
    expect(response.status()).toBe(401);
  });
});

test.describe('Admin Portal API Endpoints', () => {
  test('GET /admin/api/tenants - should list physical tenants', async ({ request }) => {
    const token = await getSessionCookie(request);
    const authHeader = { cookie: `admin_session=${token}` };
    const response = await request.get(`${targetMiddlewareUrl}/admin/api/tenants`, {
      headers: authHeader
    });
    expect(response.status()).toBe(200);
    const list = await response.json();
    expect(Array.isArray(list)).toBeTruthy();

    if (!liveMiddlewareUrl) {
      expect(list).toEqual([
        {
          slug: 'nexaduo',
          name: 'NexaDuo Main',
          chatwootUrl: 'https://chat.nexaduo.com',
          difyUrl: 'https://dify.nexaduo.com'
        },
        {
          slug: 'acme-dedicated',
          name: 'Acme Dedicated',
          chatwootUrl: 'https://chat.acme.com',
          difyUrl: 'https://dify.acme.com'
        }
      ]);
    } else {
      if (list.length > 0) {
        expect(list[0]).toHaveProperty('slug');
        expect(list[0]).toHaveProperty('name');
        expect(list[0]).toHaveProperty('chatwootUrl');
        expect(list[0]).toHaveProperty('difyUrl');
      }
    }
  });

  test('GET /admin/api/tenants/:tenantSlug/accounts - should list client accounts', async ({ request }) => {
    const token = await getSessionCookie(request);
    const authHeader = { cookie: `admin_session=${token}` };
    const response = await request.get(`${targetMiddlewareUrl}/admin/api/tenants/${targetTenantSlug}/accounts`, {
      headers: authHeader
    });
    expect(response.status()).toBe(200);
    const accounts = await response.json();
    expect(Array.isArray(accounts)).toBeTruthy();

    if (!liveMiddlewareUrl) {
      expect(accounts).toEqual([
        {
          slug: 'miau-duda',
          subdomain: 'duda',
          name: 'Miau Duda',
          chatwootAccountId: '12',
          status: 'active',
          difyAppType: 'chatflow'
        }
      ]);
    } else {
      if (accounts.length > 0) {
        expect(accounts[0]).toHaveProperty('slug');
        expect(accounts[0]).toHaveProperty('subdomain');
        expect(accounts[0]).toHaveProperty('name');
        expect(accounts[0]).toHaveProperty('chatwootAccountId');
        expect(accounts[0]).toHaveProperty('status');
      }
    }
  });

  test('POST /admin/api/tenants/:tenantSlug/provision - should orchestrate account creation and return 201', async ({ request }) => {
    // This test performs structural mutation mocks and MUST run against the local test server
    mockAxiosRequests.length = 0;
    mockDb.queries.length = 0;

    const payload = {
      name: 'Client Co',
      email: 'admin@client.co',
      adminName: 'Client Admin',
      subdomain: 'client-slug',
      difyApiKey: 'app-key-val',
      difyAppType: 'agent'
    };

    const token = await getSessionCookie(request);
    const authHeader = { cookie: `admin_session=${token}` };

    const response = await request.post(`${testMiddlewareUrl}/admin/api/tenants/nexaduo/provision`, {
      headers: authHeader,
      data: payload
    });

    expect(response.status()).toBe(201);
    const body = await response.json();
    // Issue #31: provision no longer creates an Evolution Instagram instance,
    // so the response carries no instanceName.
    expect(body).toEqual({
      status: 'success',
      accountId: '456',
      message: 'Account created and mapped under selected tenant.'
    });

    // Verify Chatwoot Platform API calls
    const accountPost = mockAxiosRequests.find(r => r.url.endsWith('/platform/api/v1/accounts') && r.method === 'POST');
    expect(accountPost).toBeDefined();
    expect(accountPost.data).toEqual({ name: 'Client Co' });
    expect(accountPost.headers.api_access_token).toBe('test-platform-token');

    const userPost = mockAxiosRequests.find(r => r.url.endsWith('/platform/api/v1/users') && r.method === 'POST');
    expect(userPost).toBeDefined();
    expect(userPost.data.name).toBe('Client Admin');
    expect(userPost.data.email).toBe('admin@client.co');

    // Verify DB insert query
    const insertQuery = mockDb.queries.find(q => q.text.includes('INSERT INTO tenants'));
    expect(insertQuery).toBeDefined();
    expect(insertQuery.values).toEqual([
      'client-slug',
      'client-slug',
      'Client Co',
      '456',
      'https://chat.nexaduo.com',
      'https://dify.nexaduo.com',
      'app-key-val',
      'agent'
    ]);

    // Issue #31: provision must NOT call the Evolution API anymore.
    const createInstancePost = mockAxiosRequests.find(r => r.url.includes('/instance/create'));
    expect(createInstancePost).toBeUndefined();
  });

  test('GET /admin/api/tenants/:tenantSlug/discovery - should return unmapped and mapped entities', async ({ request }) => {
    const token = await getSessionCookie(request);
    const authHeader = { cookie: `admin_session=${token}` };
    const response = await request.get(`${testMiddlewareUrl}/admin/api/tenants/nexaduo/discovery`, {
      headers: authHeader
    });
    expect(response.status()).toBe(200);
    const body = await response.json();
    expect(body).toHaveProperty('chatwootAccounts');
    expect(body).toHaveProperty('difyApps');
    // Issue #31: discovery no longer returns Evolution instances.
    expect(body).not.toHaveProperty('evolutionInstances');

    // Check Chatwoot accounts mapping
    const cw = body.chatwootAccounts;
    expect(cw).toContainEqual({ id: '1', name: 'Admin Principal', mapped: false });
    expect(cw).toContainEqual({ id: '12', name: 'Miau Duda', mapped: true });
    expect(cw).toContainEqual({ id: '99', name: 'Some Unmapped Account', mapped: false });

    // Check Dify apps mapping
    const dify = body.difyApps;
    expect(dify).toContainEqual({ id: 'dify-app-1', name: 'Acme AI Assistant', mode: 'agent-chat', apiKey: 'app-dify-api-key-1', mapped: true });
    expect(dify).toContainEqual({ id: 'dify-app-2', name: 'Unmapped Dify Bot', mode: 'chat', apiKey: 'app-dify-api-key-2', mapped: false });
  });

  test('POST /admin/api/tenants/:tenantSlug/import - should import existing Chatwoot account mapping and return 201', async ({ request }) => {
    mockAxiosRequests.length = 0;
    mockDb.queries.length = 0;

    const payload = {
      chatwootAccountId: '99',
      name: 'Some Unmapped Account',
      subdomain: 'unmapped-slug',
      difyApiKey: 'app-dify-api-key-2',
      difyAppType: 'chatflow'
    };

    const token = await getSessionCookie(request);
    const authHeader = { cookie: `admin_session=${token}` };

    const response = await request.post(`${testMiddlewareUrl}/admin/api/tenants/nexaduo/import`, {
      headers: authHeader,
      data: payload
    });

    expect(response.status()).toBe(201);
    const body = await response.json();
    // Issue #31: import no longer creates an Evolution Instagram instance.
    expect(body).toEqual({
      status: 'success',
      accountId: '99',
      message: 'Account imported and mapped successfully.'
    });

    // Verify DB insert query
    const insertQuery = mockDb.queries.find(q => q.text.includes('INSERT INTO tenants'));
    expect(insertQuery).toBeDefined();
    expect(insertQuery.values).toEqual([
      'unmapped-slug',
      'unmapped-slug',
      'Some Unmapped Account',
      '99',
      'https://chat.nexaduo.com',
      'https://dify.nexaduo.com',
      'app-dify-api-key-2',
      'chatflow'
    ]);

    // Issue #31: import must NOT call the Evolution API anymore.
    const createInstancePost = mockAxiosRequests.find(r => r.url.includes('/instance/create') && r.method === 'POST');
    expect(createInstancePost).toBeUndefined();
  });

  test('GET /admin/api/accounts - lists accounts with difyApiKeySet, never the key', async ({ request }) => {
    const token = await getSessionCookie(request);
    const response = await request.get(`${targetMiddlewareUrl}/admin/api/accounts`, {
      headers: { cookie: `admin_session=${token}` }
    });
    expect(response.status()).toBe(200);
    const text = await response.text();
    // The raw key/column must never leak to the client.
    expect(text).not.toContain('dify_api_key');
    const body = JSON.parse(text);
    expect(Array.isArray(body)).toBe(true);
    if (!liveMiddlewareUrl) {
      expect(body).toContainEqual(expect.objectContaining({ slug: 'duda', difyAppType: 'agent', difyApiKeySet: true }));
    }
    for (const acc of body) {
      expect(acc).toHaveProperty('difyApiKeySet');
      expect(typeof acc.difyApiKeySet).toBe('boolean');
      expect(acc).not.toHaveProperty('difyApiKey');
    }
  });

  test('PUT /admin/api/accounts/:slug/dify - rejects an invalid app type', async ({ request }) => {
    const token = await getSessionCookie(request);
    const response = await request.put(`${targetMiddlewareUrl}/admin/api/accounts/duda/dify`, {
      headers: { cookie: `admin_session=${token}` },
      data: { difyAppType: 'bogus' }
    });
    expect(response.status()).toBe(400);
    expect((await response.json()).error).toBe('invalid_dify_app_type');
  });

  test('PUT /admin/api/accounts/:slug/dify - updates and never echoes the key', async ({ request }) => {
    if (liveMiddlewareUrl) test.skip(true, 'mutating test runs only against the in-process mock server');
    const token = await getSessionCookie(request);
    const response = await request.put(`${testMiddlewareUrl}/admin/api/accounts/duda/dify`, {
      headers: { cookie: `admin_session=${token}` },
      data: { difyAppType: 'agent', difyApiKey: 'app-supersecret-xyz' }
    });
    expect(response.status()).toBe(200);
    const text = await response.text();
    expect(text).not.toContain('app-supersecret-xyz');
    expect(JSON.parse(text)).toMatchObject({ status: 'success', slug: 'duda', difyAppType: 'agent', difyApiKeyUpdated: true });
  });
});

test.describe('Omnichannel Admin Portal Browser UI rendering', () => {
  test('should render landing page on /admin', async ({ page, context, request }) => {
    const token = await getSessionCookie(request);
    await context.addCookies([{
      name: 'admin_session',
      value: token,
      domain: new URL(targetMiddlewareUrl).hostname,
      path: '/'
    }]);
    await page.goto(`${targetMiddlewareUrl}/admin`);
    await expect(page.locator('h1')).toContainText('Selecione o Tenant de Destino');
  });

  test('should render dashboard page on /admin/:tenantSlug', async ({ page, context, request }) => {
    const token = await getSessionCookie(request);
    await context.addCookies([{
      name: 'admin_session',
      value: token,
      domain: new URL(targetMiddlewareUrl).hostname,
      path: '/'
    }]);
    await page.goto(`${targetMiddlewareUrl}/admin/${targetTenantSlug}`);
    await expect(page.locator('#active-tenant-title')).toContainText('Ambiente');
  });

  // Regression: the provision form used to require manually pasting the Dify API
  // key. It now lists the registered Dify apps (from /discovery) in a dropdown, and
  // selecting one auto-fills the (readonly) API key and infers the app type from the
  // Dify mode. Guards against the dropdown not populating, not filtering already-mapped
  // apps, or not auto-filling key/type. Mock-data specific -> only against the
  // in-process mock server (discovery returns the seeded dify-app-1/2).
  test('provision form: selecting a Dify app auto-fills the API key and type', async ({ page, context, request }) => {
    test.skip(!!liveMiddlewareUrl, 'asserts seeded mock Dify discovery data');

    const token = await getSessionCookie(request);
    await context.addCookies([{
      name: 'admin_session',
      value: token,
      domain: new URL(targetMiddlewareUrl).hostname,
      path: '/'
    }]);
    await page.goto(`${targetMiddlewareUrl}/admin/${targetTenantSlug}`);

    const select = page.locator('#input-dify-select');
    // Unmapped app with an API key shows up...
    await expect(select.locator('option', { hasText: 'Unmapped Dify Bot (chat)' })).toHaveCount(1);
    // ...and the already-mapped app (Acme AI Assistant) is filtered out.
    await expect(select.locator('option', { hasText: 'Acme AI Assistant' })).toHaveCount(0);

    // Selecting the app auto-fills the key (readonly) and maps mode 'chat' -> chatflow.
    await select.selectOption({ label: 'Unmapped Dify Bot (chat)' });
    await expect(page.locator('#input-dify-key')).toHaveValue('app-dify-api-key-2');
    await expect(page.locator('#input-dify-key')).toHaveJSProperty('readOnly', true);
    await expect(page.locator('#input-dify-type')).toHaveValue('chatflow');

    // Switching back to manual clears and unlocks the key.
    await select.selectOption('manual');
    await expect(page.locator('#input-dify-key')).toHaveValue('');
    await expect(page.locator('#input-dify-key')).toHaveJSProperty('readOnly', false);
  });
});
