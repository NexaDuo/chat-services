import { test, expect, vi } from 'vitest';
import { registerTenantRoute } from './tenant.js';
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
