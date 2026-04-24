import { test, expect } from '@playwright/test';

const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'alexandre@nexaduo.com';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD;

test.describe('Initial Onboarding', () => {
  test.beforeAll(() => {
    if (!ADMIN_PASSWORD) throw new Error('ADMIN_PASSWORD not set');
  });

  test('Setup Chatwoot Admin', async ({ page }) => {
    await page.goto('http://localhost:3000/installation/onboarding');
    
    if (page.url().includes('/login')) {
      console.log('Chatwoot already configured');
      return;
    }

    await page.fill('input[name="user[name]"]', 'NexaDuo Admin');
    await page.fill('input[name="user[company]"]', 'NexaDuo');
    await page.fill('input[name="user[email]"]', ADMIN_EMAIL);
    await page.fill('input[name="user[password]"]', ADMIN_PASSWORD);
    await page.click('button[type="submit"]');

    await expect(page).toHaveURL(/.*\/login|.*\/app/);
  });

  test('Setup Dify Admin', async ({ page }) => {
    await page.goto('http://localhost:3001/install');
    
    if (page.url().includes('/signin')) {
      console.log('Dify already configured');
      return;
    }

    await page.getByPlaceholder(/email/i).fill(ADMIN_EMAIL);
    await page.getByPlaceholder(/name/i).fill('NexaDuo');
    
    const passwordInputs = page.locator('input[type="password"]');
    await passwordInputs.nth(0).fill(ADMIN_PASSWORD);
    if (await passwordInputs.count() >= 2) {
      await passwordInputs.nth(1).fill(ADMIN_PASSWORD);
    }

    await page.locator('button[type="submit"], button:has-text("Set up")').first().click();
    await expect(page).toHaveURL(/.*\/(signin|apps)/, { timeout: 30000 });
  });
});
