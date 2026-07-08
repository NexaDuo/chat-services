import { test, expect } from '@playwright/test';
import { requireEnv } from './helpers/creds';

const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'alexandre@nexaduo.com';
const CHATWOOT_URL = process.env.CHATWOOT_URL || 'https://chat.nexaduo.com';

test('Chatwoot Login Test Brute Force', async ({ page }) => {
  const ADMIN_PASSWORD = requireEnv('ADMIN_PASSWORD');
  test.setTimeout(60000);
  await page.goto(`${CHATWOOT_URL}/app/login`);
  await page.waitForTimeout(10000);

  console.log('- Clicking around to find inputs...');
  await page.keyboard.press('Tab');
  await page.keyboard.type(ADMIN_EMAIL);
  await page.keyboard.press('Tab');
  await page.keyboard.type(ADMIN_PASSWORD);
  await page.keyboard.press('Enter');

  await page.waitForTimeout(10000);
  console.log('Current URL:', page.url());
  await page.screenshot({ path: 'chatwoot-login-brute.png' });
});
