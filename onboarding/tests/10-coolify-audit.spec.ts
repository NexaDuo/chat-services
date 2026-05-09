import { test, expect } from '@playwright/test';

const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'alexandre@nexaduo.com';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD;
const COOLIFY_URL = 'https://coolify.nexaduo.com';

test.describe('Coolify UI Audit', () => {
  
  test('Check Servers and Resources', async ({ page }) => {
    test.setTimeout(120000);
    console.log(`- Navigating to ${COOLIFY_URL}/login...`);
    await page.goto(`${COOLIFY_URL}/login`, { waitUntil: 'load' });

    console.log('- Logging in...');
    await page.fill('input[name="email"]', ADMIN_EMAIL);
    await page.fill('input[name="password"]', ADMIN_PASSWORD!);
    await page.click('button[type="submit"]');

    console.log('- Waiting for dashboard...');
    await page.waitForURL(/\/(dashboard|projects|servers)/, { timeout: 30000 });

    console.log('- Checking Servers page...');
    await page.goto(`${COOLIFY_URL}/servers`);
    await page.waitForTimeout(5000);
    
    const serverRows = page.locator('table, .grid, .card').filter({ hasText: 'localhost' });
    const serverCount = await serverRows.count();
    console.log(`- Servers found with "localhost": ${serverCount}`);

    console.log('- Checking Projects page...');
    await page.goto(`${COOLIFY_URL}/projects`);
    await page.waitForTimeout(5000);
    
    const projectCards = page.locator('.card, a[href*="/project/"]');
    const projectCount = await projectCards.count();
    console.log(`- Projects found: ${projectCount}`);
    
    const bodyText = await page.innerText('body');
    console.log('- Body Text Preview:', bodyText.substring(0, 500).replace(/\n/g, ' '));

    expect(serverCount).toBeGreaterThan(0);
    expect(projectCount).toBeGreaterThan(0);
  });
});
