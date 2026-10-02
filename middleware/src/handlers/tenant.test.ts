import { readFileSync } from 'node:fs';
import { test, expect, vi } from 'vitest';
import { registerTenantBrandingRoute, registerTenantRoute } from './tenant.js';
import Fastify from 'fastify';

test('resolve-tenant returns infra overrides', async () => {
  const app = Fastify();
  const mockConfig = { handoff: { sharedSecret: 'test-secret' } };
  const mockPool = {
    query: vi.fn().mockResolvedValue({
      rows: [{
        chatwoot_account_id: 123,
        infra_type: 'dedicated',
        chatwoot_url: 'https://cw.example.com',
        dify_url: 'https://dify.example.com'
      }]
    })
  };

  await registerTenantRoute(app as any, mockConfig as any, mockPool as any);

  const response = await app.inject({
    method: 'GET',
    url: '/resolve-tenant',
    query: { subdomain: 'test' },
    headers: { authorization: 'Bearer test-secret' }
  });

  expect(response.statusCode).toBe(200);
  const body = JSON.parse(response.payload);
  expect(body).toEqual({
    subdomain: 'test',
    accountId: 123,
    infraType: 'dedicated',
    overrides: {
      chatwootUrl: 'https://cw.example.com',
      difyUrl: 'https://dify.example.com'
    }
  });
});

// --- GET /public/tenant-branding (issue #273) --------------------------------

// The exact bytes this route answers with are the contract with its consumer,
// deploy/open_graph.rb inside chatwoot-rails. The same file is fed to the Ruby
// contract (scripts/tests/chatwoot-open-graph-contract.rb), so a change in the
// serialization here cannot pass without the consumer being run against it.
const GOLDEN = readFileSync(
  new URL('../../../scripts/tests/fixtures/tenant-branding-response.json', import.meta.url),
  'utf8',
).trim();

const ownerRow = (overrides: Record<string, unknown> = {}) => ({
  chatwoot_url: 'https://chat.example.test',
  og_title: 'Acme Atendimento',
  og_description: 'Fale com a Acme: suporte & vendas "24h" <em um só lugar>.',
  og_image_url: 'https://chat.example.test/og-images/acme.png',
  ...overrides,
});

async function brandingApp(rows: unknown[] | Error) {
  const app = Fastify();
  const query = rows instanceof Error ? vi.fn().mockRejectedValue(rows) : vi.fn().mockResolvedValue({ rows });
  await registerTenantBrandingRoute(app as any, { query } as any);
  const get = (host?: string) =>
    app.inject({ method: 'GET', url: '/public/tenant-branding', query: host === undefined ? {} : { host } });
  return { app, query, get };
}

test('tenant-branding answers without credentials with exactly the golden payload', async () => {
  const { get } = await brandingApp([ownerRow()]);
  const response = await get('chat.example.test');

  expect(response.statusCode).toBe(200);
  expect(response.headers['content-type']).toMatch(/^application\/json/);
  expect(response.headers['cache-control']).toBe('public, max-age=60');
  expect(response.payload).toBe(GOLDEN);
});

test('tenant-branding never leaks other tenant columns', async () => {
  const { get } = await brandingApp([
    ownerRow({ slug: 'acme', dify_api_key: 'app-secret', chatwoot_account_id: '1', dify_url: 'https://dify.example.test' }),
  ]);
  const response = await get('chat.example.test');

  expect(Object.keys(JSON.parse(response.payload)).sort()).toEqual(['ogDescription', 'ogImageUrl', 'ogTitle']);
  expect(response.payload).not.toContain('app-secret');
  expect(response.payload).not.toContain('dify');
});

test('tenant-branding only considers the active owner (Chatwoot account 1) of a host', async () => {
  const { get, query } = await brandingApp([ownerRow()]);
  await get('chat.example.test');

  const sql = String(query.mock.calls[0][0]).replace(/\s+/g, ' ');
  expect(sql).toContain("WHERE status = 'active' AND chatwoot_account_id = '1' AND chatwoot_url IS NOT NULL");
  expect(sql).toContain('ORDER BY created_at, slug');
  // No request input reaches the query: the host is matched in memory.
  expect(query.mock.calls[0][1]).toBeUndefined();
});

test('tenant-branding matches the host case-insensitively, ignoring scheme, port and path of chatwoot_url', async () => {
  const { get } = await brandingApp([
    ownerRow({ chatwoot_url: 'not a url', og_title: 'Broken' }),
    ownerRow({ chatwoot_url: 'http://Chat.Example.Test:3000/app', og_title: 'First owner' }),
    ownerRow({ og_title: 'Second owner' }),
  ]);
  const response = await get('CHAT.example.test');

  expect(response.statusCode).toBe(200);
  expect(JSON.parse(response.payload).ogTitle).toBe('First owner');
});

test('tenant-branding returns 404 for a host no tenant owns', async () => {
  const { get } = await brandingApp([ownerRow()]);
  const response = await get('help.other.test');

  expect(response.statusCode).toBe(404);
  expect(JSON.parse(response.payload)).toEqual({ error: 'tenant_not_found' });
});

test('tenant-branding rejects anything that is not a bare hostname before touching the database', async () => {
  const { get, query } = await brandingApp([ownerRow()]);
  const invalid = [
    undefined,
    '',
    'chat.example.test:3000',
    'https://chat.example.test',
    'chat.example.test/x',
    "chat'; DROP TABLE tenants;--",
    '-chat.example.test',
    'a'.repeat(254),
  ];
  for (const host of invalid) {
    const response = await get(host);
    expect(response.statusCode, `host=${String(host)}`).toBe(400);
    expect(JSON.parse(response.payload)).toEqual({ error: 'invalid_query' });
  }
  expect(query).not.toHaveBeenCalled();
});

test('tenant-branding blanks empty fields and drops an og_image_url that is not an absolute http(s) URL', async () => {
  const invalid = ['/og-images/acme.png', 'javascript:alert(1)', 'https://x.test/a b.png', 'https://x.test/"onload=', '   '];
  for (const image of invalid) {
    const { get } = await brandingApp([ownerRow({ og_title: '  ', og_description: null, og_image_url: image })]);
    const response = await get('chat.example.test');
    expect(JSON.parse(response.payload), `og_image_url=${image}`).toEqual({
      ogTitle: null,
      ogDescription: null,
      ogImageUrl: null,
    });
  }
});

test('tenant-branding caches the owner list, so repeated calls do not reach Postgres', async () => {
  const { get, query } = await brandingApp([ownerRow()]);
  await get('chat.example.test');
  await get('help.other.test');
  await get('chat.example.test');

  expect(query).toHaveBeenCalledTimes(1);
});

test('tenant-branding answers 503 on a database error and does not cache it', async () => {
  const { get, query } = await brandingApp(new Error('connection refused'));
  expect((await get('chat.example.test')).statusCode).toBe(503);

  query.mockResolvedValue({ rows: [ownerRow()] });
  expect((await get('chat.example.test')).statusCode).toBe(200);
});
