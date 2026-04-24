import { test, expect } from '@playwright/test';

const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'alexandre@nexaduo.com';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD;

test.describe('Smoke Tests (Post-Setup)', () => {
  test('Login to Chatwoot', async ({ page }) => {
    await page.goto('http://localhost:3000/app/login', { waitUntil: 'load', timeout: 60000 });
    
    // Espera por qualquer um dos estados: formulário de login OU dashboard logada
    const loginForm = page.getByPlaceholder(/email/i).or(page.locator('input[name="email"]'));
    const dashboardElement = page.locator('.sidebar, .top-bar, .user-profile, .brand-name');

    // Espera até que um dos dois apareça
    await Promise.race([
      loginForm.first().waitFor({ state: 'visible', timeout: 15000 }).catch(() => {}),
      dashboardElement.first().waitFor({ state: 'visible', timeout: 15000 }).catch(() => {})
    ]);

    if (page.url().includes('/app/accounts') || page.url().includes('/dashboard') || await dashboardElement.first().isVisible()) {
      console.log('  - Chatwoot: Detected active session. Already logged in.');
      return;
    }

    console.log('  - Chatwoot: No active session. Proceeding with login...');
    await loginForm.first().fill(ADMIN_EMAIL);
    await page.getByPlaceholder(/password/i).or(page.locator('input[type="password"]')).first().fill(ADMIN_PASSWORD!);
    await page.locator('button[type="submit"], button:has-text("Login"), button:has-text("Entrar")').first().click();
    
    await expect(page).toHaveURL(/.*\/app\/accounts|.*\/app\/dashboard/, { timeout: 30000 });
  });

  test('Login to Dify', async ({ page }) => {
    await page.goto('http://localhost:3001/signin', { waitUntil: 'load', timeout: 60000 });
    
    const loginForm = page.getByPlaceholder(/email/i).or(page.locator('input[name="email"]'));
    const dashboardElement = page.locator('nav, .apps-grid, .avatar, button:has-text("Create App")');

    await Promise.race([
      loginForm.first().waitFor({ state: 'visible', timeout: 15000 }).catch(() => {}),
      dashboardElement.first().waitFor({ state: 'visible', timeout: 15000 }).catch(() => {})
    ]);

    if (page.url().includes('/apps') || page.url().includes('/datasets') || await dashboardElement.first().isVisible()) {
      console.log('  - Dify: Detected active session. Already logged in.');
      return;
    }

    console.log('  - Dify: No active session. Proceeding with login...');
    await loginForm.first().fill(ADMIN_EMAIL);
    await page.getByPlaceholder(/password/i).or(page.locator('input[type="password"]')).first().fill(ADMIN_PASSWORD!);
    await page.locator('button[type="submit"], button:has-text("Sign in"), button:has-text("Entrar")').first().click();
    
    await expect(page).toHaveURL(/.*\/apps/, { timeout: 30000 });
  });

  test('Access Grafana Login Page', async ({ page }) => {
    await page.goto('http://localhost:3002/login');
    await expect(page.locator('input[name="user"]')).toBeVisible();
  });
});
