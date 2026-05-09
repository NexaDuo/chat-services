import { test, expect } from '@playwright/test';

test('Dify Login Page Audit', async ({ page }) => {
  await page.goto('https://dify.nexaduo.com/signin');
  await page.waitForTimeout(10000);
  await page.screenshot({ path: 'dify-signin-debug.png' });
  const bodyText = await page.innerText('body');
  console.log('Body text:', bodyText.substring(0, 500).replace(/\n/g, ' '));
  const hasGoogle = bodyText.includes('Google');
  console.log('Has Google button text?', hasGoogle);
});
