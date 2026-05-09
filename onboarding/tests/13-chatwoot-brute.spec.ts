import { test, expect } from '@playwright/test';

const ADMIN_EMAIL = 'alexandre@nexaduo.com';
const ADMIN_PASSWORD = 'NexaDuo@2026-C9E5FF39';
const CHATWOOT_URL = 'https://chat.nexaduo.com';

test('Chatwoot Login Test Brute Force', async ({ page }) => {
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
