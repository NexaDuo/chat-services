import { test, expect } from '@playwright/test';

const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'alexandre@nexaduo.com';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD;

test.describe('Smoke Tests (Post-Setup)', () => {
  test('Login to Chatwoot', async ({ page }) => {
    test.setTimeout(120000); // Aumenta timeout para este teste específico
    
    console.log('  - Chatwoot: Navigating to login page...');
    await page.goto('http://localhost:3000/app/login', { waitUntil: 'networkidle', timeout: 60000 });
    
    // Log URL atual para debug
    console.log(`  - Chatwoot: Current URL: ${page.url()}`);

    // Espera por qualquer um dos estados: formulário de login OU dashboard logada
    // No Chatwoot v4, o seletor pode ser mais complexo devido ao Shadow DOM ou labels dinâmicos
    const loginForm = page.locator('input[name="email"], input[type="email"], [placeholder*="email" i]');
    const dashboardElement = page.locator('.sidebar, .top-bar, .user-profile, .brand-name');

    // Espera até que um dos dois apareça (aumentado para 30s)
    await Promise.race([
      loginForm.first().waitFor({ state: 'visible', timeout: 30000 }).catch(() => {}),
      dashboardElement.first().waitFor({ state: 'visible', timeout: 30000 }).catch(() => {})
    ]);

    if (page.url().includes('/app/accounts') || page.url().includes('/dashboard') || await dashboardElement.first().isVisible()) {
      console.log('  - Chatwoot: Detected active session. Already logged in.');
      return;
    }

    if (!await loginForm.first().isVisible()) {
      console.log('  - Chatwoot: Login form not visible. Diagnostic info:');
      console.log(`  - URL: ${page.url()}`);
      const inputs = await page.locator('input').all();
      console.log(`  - Found ${inputs.length} input fields:`);
      for (const input of inputs) {
        const name = await input.getAttribute('name');
        const type = await input.getAttribute('type');
        const placeholder = await input.getAttribute('placeholder');
        console.log(`    * input[name="${name}"][type="${type}"][placeholder="${placeholder}"]`);
      }
      const bodyVisible = await page.locator('body').isVisible();
      console.log(`  - Body visible: ${bodyVisible}`);
    }

    console.log('  - Chatwoot: No active session. Proceeding with login...');
    
    // Tenta encontrar o campo de email de várias formas
    const emailInput = page.locator('input[name="email"], input[type="email"], [placeholder*="email" i], input[id*="email" i]').first();
    await emailInput.waitFor({ state: 'visible', timeout: 45000 });
    await emailInput.fill(ADMIN_EMAIL);

    const passwordInput = page.locator('input[name="password"], input[type="password"], [placeholder*="password" i], input[id*="password" i]').first();
    await passwordInput.fill(ADMIN_PASSWORD!);
    
    await page.locator('button[type="submit"], button:has-text("Login"), button:has-text("Entrar")').first().click();
    
    await expect(page).toHaveURL(/.*\/app\/accounts|.*\/app\/dashboard/, { timeout: 60000 });
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
    
    const emailInput = page.locator('input[name="email"], input[type="email"], [placeholder*="email" i]').first();
    await emailInput.waitFor({ state: 'visible', timeout: 30000 });
    await emailInput.fill(ADMIN_EMAIL);

    const passwordInput = page.locator('input[name="password"], input[type="password"], [placeholder*="password" i]').first();
    await passwordInput.fill(ADMIN_PASSWORD!);

    await page.locator('button[type="submit"], button:has-text("Sign in"), button:has-text("Entrar")').first().click();
    
    await expect(page).toHaveURL(/.*\/apps/, { timeout: 30000 });
  });

  test('Access Grafana Login Page', async ({ page }) => {
    await page.goto('http://localhost:3002/login');
    await expect(page.locator('input[name="user"]')).toBeVisible();
  });
});
