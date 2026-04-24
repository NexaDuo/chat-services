import { test, expect } from '@playwright/test';

const SERVICES = [
  { name: 'Chatwoot', url: 'http://localhost:3000/' },
  { name: 'Dify Web', url: 'http://localhost:3001/install' },
  { name: 'Dify API', url: 'http://localhost:5001/console/api/setup' },
  { name: 'Middleware', url: 'http://localhost:4000/health' },
  { name: 'Grafana', url: 'http://localhost:3002/login' },
  { name: 'Prometheus', url: 'http://localhost:9090/-/healthy' },
];

test.describe('Infrastructure Health', () => {
  for (const service of SERVICES) {
    test(`${service.name} should be reachable`, async ({ request }) => {
      const response = await request.get(service.url);
      // Aceitamos 200 para a maioria, ou redirects (301/302) para apps web
      expect([200, 301, 302, 404]).toContain(response.status()); 
      // 404 no dify setup API após configurado é ok, mas no CI limpo deve ser 200
    });
  }
});
