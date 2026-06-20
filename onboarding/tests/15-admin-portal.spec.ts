import { test, expect } from '@playwright/test';
import Fastify, { FastifyInstance } from 'fastify';
import axios from '../../middleware/node_modules/axios/index.js';
import { registerAdminRoutes } from '../../middleware/src/handlers/admin.js';

const MIDDLEWARE_URL = 'http://127.0.0.1:4000';
let server: FastifyInstance;

// Mock database pool
const mockDb = {
  queries: [] as { text: string; values: any[] }[],
  query: async (text: string, values?: any[]) => {
    mockDb.queries.push({ text, values: values || [] });
    
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

    return { rows: [] };
  }
};

// Mock Axios calls
const mockAxiosRequests: any[] = [];
test.beforeAll(async () => {
  // Overwrite axios methods
  axios.post = async (url: string, data?: any, config?: any) => {
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
  };

  axios.get = async (url: string, config?: any) => {
    mockAxiosRequests.push({ method: 'GET', url, headers: config?.headers });
    if (url.includes('/instance/connectionState')) {
      return { data: { instance: { state: 'open' } } };
    }
    return { data: {} };
  };

  server = Fastify({
    logger: false
  });
  
  const mockConfig = {
    adminPassword: 'test-admin-password',
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
  
  await registerAdminRoutes(server, mockConfig as any, mockDb as any);
  await server.listen({ port: 4000, host: '127.0.0.1' });
});

test.afterAll(async () => {
  await server.close();
});

test.describe('Omnichannel Admin Portal Authentication', () => {
  test('should return 401 when accessing /admin without authorization headers', async ({ request }) => {
    const response = await request.get(`${MIDDLEWARE_URL}/admin`);
    expect(response.status()).toBe(401);
  });

  test('should return 200 when accessing /admin with correct credentials', async ({ request }) => {
    const credentials = Buffer.from('admin:test-admin-password').toString('base64');
    const response = await request.get(`${MIDDLEWARE_URL}/admin`, {
      headers: { authorization: `Basic ${credentials}` }
    });
    expect(response.status()).toBe(200);
    const body = await response.text();
    expect(body).toContain('Omnichannel Admin Portal');
  });
});

test.describe('Admin Portal API Endpoints', () => {
  const credentials = Buffer.from('admin:test-admin-password').toString('base64');
  const authHeader = { authorization: `Basic ${credentials}` };

  test('GET /admin/api/tenants - should list physical tenants', async ({ request }) => {
    const response = await request.get(`${MIDDLEWARE_URL}/admin/api/tenants`, {
      headers: authHeader
    });
    expect(response.status()).toBe(200);
    const list = await response.json();
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
  });

  test('GET /admin/api/tenants/:tenantSlug/accounts - should list client accounts', async ({ request }) => {
    const response = await request.get(`${MIDDLEWARE_URL}/admin/api/tenants/nexaduo/accounts`, {
      headers: authHeader
    });
    expect(response.status()).toBe(200);
    const accounts = await response.json();
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
  });

  test('POST /admin/api/tenants/:tenantSlug/provision - should orchestrate account creation and return 201', async ({ request }) => {
    // Clear request lists before testing
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

    const response = await request.post(`${MIDDLEWARE_URL}/admin/api/tenants/nexaduo/provision`, {
      headers: authHeader,
      data: payload
    });

    expect(response.status()).toBe(201);
    const body = await response.json();
    expect(body).toEqual({
      status: 'success',
      accountId: '456',
      instanceName: 'client-slug-instagram',
      message: 'Account created and instance initialized under selected tenant.'
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

    // Verify Evolution API calls
    const createInstancePost = mockAxiosRequests.find(r => r.url.includes('/instance/create'));
    expect(createInstancePost).toBeDefined();
    expect(createInstancePost.data).toEqual({
      instanceName: 'client-slug-instagram',
      token: '',
      integration: 'instagram',
      qrcode: false
    });
  });

  test('GET /admin/api/instances/:name/status - should return connectionState', async ({ request }) => {
    const response = await request.get(`${MIDDLEWARE_URL}/admin/api/instances/client-slug-instagram/status`, {
      headers: authHeader
    });
    expect(response.status()).toBe(200);
    const body = await response.json();
    expect(body).toEqual({
      instanceName: 'client-slug-instagram',
      connectionState: 'open'
    });
  });
});

test.describe('Omnichannel Admin Portal Browser UI rendering', () => {
  test('should render landing page on /admin', async ({ page }) => {
    const credentials = Buffer.from('admin:test-admin-password').toString('base64');
    await page.setExtraHTTPHeaders({ authorization: `Basic ${credentials}` });
    await page.goto(`${MIDDLEWARE_URL}/admin`);
    await expect(page.locator('h1')).toContainText('Selecione o Tenant de Destino');
  });

  test('should render dashboard page on /admin/:tenantSlug', async ({ page }) => {
    const credentials = Buffer.from('admin:test-admin-password').toString('base64');
    await page.setExtraHTTPHeaders({ authorization: `Basic ${credentials}` });
    await page.goto(`${MIDDLEWARE_URL}/admin/nexaduo`);
    await expect(page.locator('#active-tenant-title')).toContainText('Ambiente');
  });
});
