import { test, expect, vi } from 'vitest';
import { resolveTenant } from './config.js';

// Regression guard for the Dify routing fix (Duda / Chatwoot account 3):
// a mapped account must resolve to its Dify app key + app type, and an
// unmapped account must resolve to null (handler then skips with
// "no_tenant_mapping" instead of erroring). This path is server-side
// (Chatwoot webhook -> middleware -> Dify), so it cannot be covered by the
// browser-based Playwright suite.

test('resolveTenant maps an account to its Dify app (agent => streaming)', async () => {
  const config = { dify: { baseUrl: 'https://dify.nexaduo.com' } };
  const pool = {
    query: vi.fn().mockResolvedValue({
      rows: [{ dify_api_key: 'app-test-key', dify_app_type: 'agent' }],
    }),
  };

  const tenant = await resolveTenant(config as any, 3, pool as any);

  expect(tenant).toEqual({
    apiKey: 'app-test-key',
    baseUrl: 'https://dify.nexaduo.com',
    appType: 'agent',
  });
  // Looked up by the Chatwoot account id, as a string.
  expect(pool.query).toHaveBeenCalledWith(expect.stringContaining('chatwoot_account_id'), ['3']);
});

test('resolveTenant returns null for an unmapped account', async () => {
  const config = { dify: { baseUrl: 'https://dify.nexaduo.com' } };
  const pool = { query: vi.fn().mockResolvedValue({ rows: [] }) };

  expect(await resolveTenant(config as any, 999, pool as any)).toBeNull();
});
