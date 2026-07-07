import { test, expect } from '@playwright/test';
import { requireEnv } from './helpers/creds';

const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'alexandre@nexaduo.com';
const CHATWOOT_URL = process.env.CHATWOOT_URL || 'https://chat.nexaduo.com';

test('Chatwoot Login Test', async ({ page }) => {
  const ADMIN_PASSWORD = requireEnv('ADMIN_PASSWORD');
  test.setTimeout(60000);
  console.log(`- Navigating to ${CHATWOOT_URL}/app/login...`);
  await page.goto(`${CHATWOOT_URL}/app/login`, { waitUntil: 'load' });

  console.log('- Waiting for form...');
  await page.waitForTimeout(5000);

  console.log('- Filling credentials...');
  // Try multiple selectors for robustness
  const emailInput = page.locator('input[name="email"], input[type="email"], label:has-text("Email") + input');
  await emailInput.first().fill(ADMIN_EMAIL);
  
  const passwordInput = page.locator('input[name="password"], input[type="password"]');
  await passwordInput.first().fill(ADMIN_PASSWORD);
  
  await page.click('button[type="submit"]');

  console.log('- Waiting for dashboard...');
  try {
    await page.waitForURL(/\/app\/accounts/, { timeout: 30000 });
    console.log('OK Chatwoot Login Success!');
  } catch (e) {
    console.log('FAIL Chatwoot Login failed. Current URL:', page.url());
    await page.screenshot({ path: 'chatwoot-login-fail.png' });
    throw e;
  }
});
