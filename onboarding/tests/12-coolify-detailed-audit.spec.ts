import { test, expect } from '@playwright/test';
import { requireEnv } from './helpers/creds';

const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'alexandre@nexaduo.com';
const COOLIFY_URL = 'https://coolify.nexaduo.com';

test('Coolify Detailed Audit', async ({ page }) => {
  const ADMIN_PASSWORD = requireEnv('ADMIN_PASSWORD');
  test.setTimeout(120000);
  console.log(`- Navigating to ${COOLIFY_URL}/login...`);
  await page.goto(`${COOLIFY_URL}/login`, { waitUntil: 'load' });

  console.log('- Logging in...');
  await page.fill('input[name="email"]', ADMIN_EMAIL);
  await page.fill('input[name="password"]', ADMIN_PASSWORD);
  await page.click('button[type="submit"]');

  console.log('- Waiting for dashboard...');
  await page.waitForURL(/\/(dashboard|projects|servers)/, { timeout: 60000 });
  console.log('- Current URL:', page.url());

  // Check current team
  const teamSelector = page.locator('button:has-text("Team"), .team-selector, [aria-label="Team Selector"]');
  if (await teamSelector.count() > 0) {
    console.log('- Current Team:', await teamSelector.first().innerText());
  }

  console.log('- Checking Servers page content...');
  await page.goto(`${COOLIFY_URL}/servers`);
  await page.waitForLoadState('networkidle');
  await page.waitForTimeout(5000);
  
  const bodyText = await page.innerText('body');
  console.log('- Servers Page Text (first 300 chars):', bodyText.substring(0, 300).replace(/\n/g, ' '));
  
  const hasLocalhost = bodyText.includes('localhost');
  console.log('- Has "localhost"?', hasLocalhost);

  console.log('- Checking Projects page content...');
  await page.goto(`${COOLIFY_URL}/projects`);
  await page.waitForLoadState('networkidle');
  await page.waitForTimeout(5000);
  
  const projectsText = await page.innerText('body');
  console.log('- Projects Page Text (first 300 chars):', projectsText.substring(0, 300).replace(/\n/g, ' '));
  
  const hasProject = projectsText.includes('nexaduo');
  console.log('- Has "nexaduo"?', hasProject);

  expect(hasLocalhost).toBeTruthy();
  expect(hasProject).toBeTruthy();
});
