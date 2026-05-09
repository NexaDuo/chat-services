import { test, expect } from '@playwright/test';

test('Debug Chatwoot Login', async ({ page }) => {
  await page.goto('https://chat.nexaduo.com/app/login');
  await page.waitForTimeout(10000);
  await page.screenshot({ path: 'chatwoot-login-debug.png' });
  console.log('Current URL:', page.url());
  const bodyText = await page.innerText('body');
  console.log('Body text:', bodyText.substring(0, 500).replace(/\n/g, ' '));
});
