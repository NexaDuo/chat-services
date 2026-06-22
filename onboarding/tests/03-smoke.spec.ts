import { test, expect } from '@playwright/test';

const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'alexandre@nexaduo.com';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD;
const CHATWOOT_URL = process.env.CHATWOOT_URL || 'http://localhost:3000';
const DIFY_URL = process.env.DIFY_URL || 'http://localhost:3001';
const GRAFANA_URL = process.env.GRAFANA_URL || 'http://localhost:3002';

test.describe('Smoke Tests (Post-Setup)', () => {
  test('Login to Chatwoot', async ({ page }) => {
    test.setTimeout(120000); 
    
    console.log(`  - Chatwoot: Navigating to ${CHATWOOT_URL}/app/login...`);
    await page.goto(`${CHATWOOT_URL}/app/login`, { waitUntil: 'networkidle', timeout: 60000 });
    
    // Espera por qualquer um dos estados: formulário de login OU dashboard logada
    const loginForm = page.locator('input[name="email"], input[name="email_address"], input[type="email"]');
    const dashboardElement = page.locator('.sidebar, .top-bar, .user-profile, .brand-name');

    // Espera até que um dos dois apareça
    await Promise.race([
      loginForm.first().waitFor({ state: 'visible', timeout: 30000 }).catch(() => {}),
      dashboardElement.first().waitFor({ state: 'visible', timeout: 30000 }).catch(() => {})
    ]);

    if (page.url().includes('/app/accounts') || page.url().includes('/dashboard') || await dashboardElement.first().isVisible()) {
      console.log('  - Chatwoot: Detected active session. Already logged in.');
      return;
    }

    console.log('  - Chatwoot: No active session. Proceeding with login...');
    
    // Chatwoot v4 uses email_address for login
    const emailInput = page.locator('input[name="email_address"], input[name="email"], input[type="email"]').first();
    await emailInput.waitFor({ state: 'visible', timeout: 30000 });
    await emailInput.fill(ADMIN_EMAIL);

    const passwordInput = page.locator('input[name="password"], input[type="password"]').first();
    await passwordInput.fill(ADMIN_PASSWORD!);
    
    await page.locator('button[type="submit"], button:has-text("Login"), button:has-text("Entrar")').first().click();
    
    await expect(page).toHaveURL(/.*\/app\/accounts|.*\/app\/dashboard/, { timeout: 60000 });
  });

  test('Login to Dify', async ({ page }) => {
    console.log(`  - Dify: Navigating to ${DIFY_URL}/signin...`);
    await page.goto(`${DIFY_URL}/signin`, { waitUntil: 'load', timeout: 60000 });
    
    const loginForm = page.getByPlaceholder(/email/i).or(page.locator('input[name="email"]'));
    const dashboardElement = page.locator('nav, .apps-grid, .avatar, button:has-text("Create App")');

    await Promise.race([
      loginForm.first().waitFor({ state: 'visible', timeout: 15000 }).catch(() => {}),
      dashboardElement.first().waitFor({ state: 'visible', timeout: 15000 }).catch(() => {})
    ]);

    const authFailures: string[] = [];
    const startMonitoring = () => {
      // Monitor refresh-token requests for 401 unauthorized errors *after* login session is established
      page.on('response', response => {
        const url = response.url();
        const status = response.status();
        if (status === 401 && url.includes('/console/api/refresh-token')) {
          authFailures.push(`[HTTP 401] ${response.request().method()} ${url}`);
        }
      });
    };

    if (page.url().includes('/apps') || page.url().includes('/datasets') || await dashboardElement.first().isVisible()) {
      console.log('  - Dify: Detected active session. Already logged in.');
      startMonitoring();
    } else {
      console.log('  - Dify: No active session. Proceeding with login...');
      
      const emailInput = page.locator('input[name="email"], input[type="email"], [placeholder*="email" i]').first();
      await emailInput.waitFor({ state: 'visible', timeout: 30000 });
      await emailInput.fill(ADMIN_EMAIL);

      const passwordInput = page.locator('input[name="password"], input[type="password"], [placeholder*="password" i]').first();
      await passwordInput.fill(ADMIN_PASSWORD!);

      await page.locator('button[type="submit"], button:has-text("Sign in"), button:has-text("Entrar")').first().click();
      
      await expect(page).toHaveURL(/.*\/apps/, { timeout: 30000 });
      startMonitoring();
    }

    // Wait a brief moment on the authenticated dashboard to capture any token refresh calls
    await page.waitForTimeout(5000);

    expect(authFailures, 'Detected unauthorized 401 errors on Dify refresh-token endpoint').toEqual([]);
  });

  test('Access Grafana Login Page', async ({ page }) => {
    console.log(`  - Grafana: Navigating to ${GRAFANA_URL}/login...`);
    await page.goto(`${GRAFANA_URL}/login`);
    await expect(page.locator('input[name="user"]')).toBeVisible();
  });
});
