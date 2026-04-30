import { test } from '@playwright/test';

const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'alexandre@nexaduo.com';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD;
const CHATWOOT_URL = process.env.CHATWOOT_URL || 'http://localhost:3000';
const DIFY_URL = process.env.DIFY_URL || 'http://localhost:3001';

test.describe('Initial Onboarding', () => {

  test('Setup Chatwoot Admin', async ({ page }) => {
    await page.goto(`${CHATWOOT_URL}/installation/onboarding`);
    
    if (page.url().includes('/login') || page.url().includes('/app/accounts')) {
      console.log('Chatwoot already configured');
      return;
    }

    await page.fill('input[name="user[name]"]', 'NexaDuo Admin');
    await page.fill('input[name="user[company]"]', 'NexaDuo');
    await page.fill('input[name="user[email]"]', ADMIN_EMAIL);
    await page.fill('input[name="user[password]"]', ADMIN_PASSWORD!);
    
    await page.click('button[type="submit"]');
    await page.waitForURL(/.*\/app\/login|.*\/app\/accounts/);
  });

  test('Setup Dify Admin', async ({ page }) => {
    test.setTimeout(60000);
    await page.goto(`${DIFY_URL}/install`);
    
    if (page.url().includes('/signin') || page.url().includes('/apps')) {
      console.log('Dify already configured');
      return;
    }

    try {
      await page.waitForSelector('input', { timeout: 10000 });
    } catch (e) {
       if (page.url().includes('/signin')) {
         console.log('Redirected to signin - Dify already configured');
         return;
       }
       throw e;
    }

    await page.getByPlaceholder(/email/i).fill(ADMIN_EMAIL);
    await page.getByPlaceholder(/name/i).fill('NexaDuo');
    
    const passwordInputs = page.locator('input[type="password"]');
    if (await passwordInputs.count() >= 2) {
      await passwordInputs.nth(0).fill(ADMIN_PASSWORD!);
      await passwordInputs.nth(1).fill(ADMIN_PASSWORD!);
    } else {
      await passwordInputs.nth(0).fill(ADMIN_PASSWORD!);
    }

    await page.locator('button[type="submit"], button:has-text("Set up")').first().click();
    await page.waitForURL(/.*\/signin|.*\/apps/);
  });
});
