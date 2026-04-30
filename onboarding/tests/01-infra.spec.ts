import { test, expect } from '@playwright/test';

const CHATWOOT_URL = process.env.CHATWOOT_URL || 'http://localhost:3000';
const DIFY_URL = process.env.DIFY_URL || 'http://localhost:3001';
const GRAFANA_URL = process.env.GRAFANA_URL || 'http://localhost:3002';

test.describe('Infrastructure Health', () => {
  const targets = [
    { name: 'Chatwoot', url: CHATWOOT_URL, path: '/' },
    { name: 'Dify Web', url: DIFY_URL, path: '/signin' },
    { name: 'Dify API', url: DIFY_URL, path: '/console/api/setup' },
    { name: 'Grafana', url: GRAFANA_URL, path: '/api/health' }
  ];

  for (const target of targets) {
    test(`${target.name} should be reachable`, async ({ request }) => {
      const response = await request.get(`${target.url}${target.path}`);
      expect(response.ok(), `${target.name} at ${target.url}${target.path} failed with status ${response.status()}`).toBeTruthy();
    });
  }
});
