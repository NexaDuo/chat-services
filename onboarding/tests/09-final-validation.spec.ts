import { test, expect } from '@playwright/test';
import { requireEnv } from './helpers/creds';

const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'alexandre@nexaduo.com';
const COOLIFY_URL = 'https://coolify.nexaduo.com';
const GRAFANA_URL = 'https://grafana.nexaduo.com';

test.describe('Final Verification Suite', () => {
  
  test('Coolify Status Sync', async ({ page }) => {
    test.setTimeout(120000);
    console.log(`  - Coolify: Opening ${COOLIFY_URL}...`);
    await page.goto(COOLIFY_URL, { waitUntil: 'load' });

    if (page.url().includes('/login') || await page.locator('input[name="email"]').isVisible()) {
      const ADMIN_PASSWORD = requireEnv('ADMIN_PASSWORD');
      console.log('  - Coolify: Logging in...');
      await page.fill('input[name="email"]', ADMIN_EMAIL);
      await page.fill('input[name="password"]', ADMIN_PASSWORD);
      await page.click('button[type="submit"]');
    }

    console.log('  - Coolify: Navigating to projects dashboard...');
    await page.goto(`${COOLIFY_URL}/dashboard`);
    await page.waitForTimeout(5000);

    const bodyText = await page.innerText('body');
    const exitedCount = (bodyText.match(/Exited/gi) || []).length;
    console.log(`  - Coolify Exited Count: ${exitedCount}`);

    expect(exitedCount).toBe(0);
  });

  test('Grafana Logs Sync', async ({ page }) => {
    test.setTimeout(120000);
    await page.goto(`${GRAFANA_URL}/login`);

    if (await page.locator('input[name="user"]').isVisible()) {
      const GRAFANA_PASSWORD = requireEnv('GRAFANA_ADMIN_PASSWORD');
      await page.fill('input[name="user"]', 'admin');
      await page.fill('input[name="password"]', GRAFANA_PASSWORD);
      await page.click('button[type="submit"]');
      await page.waitForTimeout(5000);
    }

    console.log('  - Grafana: Navigating to logs-prod...');
    await page.goto(`${GRAFANA_URL}/d/stack-logs-final?orgId=1&refresh=10s&from=now-1h&to=now`, { waitUntil: 'networkidle' });
    await page.waitForTimeout(10000);

    const logs = page.locator('[role="row"], .logs-row, .log-row');
    const count = await logs.count();
    console.log(`  - Grafana Logs count: ${count}`);

    expect(count).toBeGreaterThan(1);
  });
});
