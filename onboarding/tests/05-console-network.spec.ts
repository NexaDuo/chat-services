import { test, expect } from '@playwright/test';

const CHATWOOT_URL = process.env.CHATWOOT_URL || 'https://chat.nexaduo.com';
const DIFY_URL = process.env.DIFY_URL || 'https://dify.nexaduo.com';
const GRAFANA_URL = process.env.GRAFANA_URL || 'https://grafana.nexaduo.com';
const COOLIFY_URL = process.env.COOLIFY_URL || 'https://coolify.nexaduo.com';

const apps = [
  { name: 'Chatwoot', url: CHATWOOT_URL },
  { name: 'Dify', url: DIFY_URL },
  { name: 'Grafana', url: GRAFANA_URL },
  { name: 'Coolify', url: COOLIFY_URL },
];

test.describe('Console and Network Error Validation', () => {
  for (const app of apps) {
    test(`Validate ${app.name} for console and network errors`, async ({ page }) => {
      const consoleErrors: string[] = [];
      const networkErrors: string[] = [];

      // Listen for console errors
      page.on('console', msg => {
        if (msg.type() === 'error') {
          // Filter out common expected noise if any (none for now)
          consoleErrors.push(`[Console Error] ${msg.text()}`);
        }
      });

      // Listen for failed requests
      page.on('requestfailed', request => {
        networkErrors.push(`[Network Error] ${request.method()} ${request.url()} - ${request.failure()?.errorText}`);
      });

      // Listen for non-ok responses
      page.on('response', response => {
        const status = response.status();
        const method = response.request().method();
        const url = response.url();
        
        // Ignore redirects and auth checks (expected in landing pages)
        if (status >= 300 && status < 400) return;
        if (status === 401 || status === 403) return;

        if (!response.ok()) {
             networkErrors.push(`[HTTP ${status}] ${method} ${url}`);
        }
        
        // Specifically check for 404s on assets (js, css, etc)
        if (status === 404 && (url.endsWith('.js') || url.endsWith('.css') || url.includes('/assets/'))) {
             networkErrors.push(`[HTTP 404 - Missing Asset] ${method} ${url}`);
        }
      });

      console.log(`Navigating to ${app.name} at ${app.url}...`);
      await page.goto(app.url, { waitUntil: 'networkidle', timeout: 90000 });

      // Wait a bit for async loads/errors
      await page.waitForTimeout(5000);

      if (consoleErrors.length > 0) {
        console.error(`Found ${consoleErrors.length} console errors in ${app.name}:`);
        consoleErrors.forEach(err => console.error(`  ${err}`));
      }

      if (networkErrors.length > 0) {
        console.error(`Found ${networkErrors.length} network errors in ${app.name}:`);
        networkErrors.forEach(err => console.error(`  ${err}`));
      }

      expect(consoleErrors, `${app.name} has console errors`).toEqual([]);
      expect(networkErrors, `${app.name} has network errors`).toEqual([]);
    });
  }
});
