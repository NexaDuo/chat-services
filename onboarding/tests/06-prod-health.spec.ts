import { test, expect } from '@playwright/test';

const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'alexandre@nexaduo.com';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD;
const COOLIFY_URL = 'https://coolify.nexaduo.com';
const GRAFANA_URL = 'https://grafana.nexaduo.com';

test.describe('Production Health Validation', () => {
  
  test('Coolify — Services should not be Exited', async ({ page }) => {
    test.setTimeout(120000);
    console.log(`  - Coolify: Navigating to ${COOLIFY_URL}/login...`);
    
    // Tenta carregar a página, se houver loop o timeout do goto pegará
    await page.goto(`${COOLIFY_URL}/login`, { waitUntil: 'load', timeout: 60000 });

    if (page.url().includes('/login') || await page.locator('input[name="email"]').isVisible()) {
      console.log('  - Coolify: Logging in...');
      await page.fill('input[name="email"]', ADMIN_EMAIL);
      await page.fill('input[name="password"]', ADMIN_PASSWORD!);
      await page.click('button[type="submit"]');
      // Espera por qualquer sinal de sucesso (URL mudar ou Dashboard aparecer)
      await page.waitForFunction(() => 
        window.location.pathname === '/' || 
        window.location.pathname.includes('dashboard') || 
        document.body.innerText.includes('Dashboard'),
        { timeout: 30000 }
      );
    }

    console.log('  - Coolify: Navigating to project "NexaDuo Chat Services"...');
    // Força a navegação para o ambiente de produção
    await page.goto(`${COOLIFY_URL}/project/ta3iapdw1fii69nyqs091f6s/environment/fx6r225ge9i6ws94if4dc2uy`, { waitUntil: 'load' });
    
    console.log('  - Coolify: Checking for service status indicators...');
    await page.waitForTimeout(10000);

    const bodyText = await page.innerText('body');
    const exitedCount = (bodyText.match(/Exited/gi) || []).length;
    const stoppedCount = (bodyText.match(/Stopped/gi) || []).length;
    
    console.log(`  - Coolify Status Summary: Exited(${exitedCount}), Stopped(${stoppedCount})`);

    expect(exitedCount, 'Found services marked as Exited').toBe(0);
    expect(stoppedCount, 'Found services marked as Stopped').toBe(0);
    console.log('  - Coolify: All services seem healthy.');
  });

  test('Grafana — Service Logs Overview should have data', async ({ page }) => {
    test.setTimeout(120000);
    console.log(`  - Grafana: Navigating to ${GRAFANA_URL}/login...`);
    await page.goto(`${GRAFANA_URL}/login`, { waitUntil: 'networkidle' });

    const userField = page.locator('input[name="user"]');
    if (await userField.isVisible()) {
      console.log('  - Grafana: Logging in...');
      await userField.fill('admin');
      await page.fill('input[name="password"]', 'NexaDuo_2026_Admin');
      await page.click('button[type="submit"]');
      await page.waitForURL(url => url.pathname === '/' || url.pathname.includes('dashboard'), { timeout: 30000 });
    }

    console.log('  - Grafana: Navigating to Service Logs Overview dashboard...');
    await page.goto(`${GRAFANA_URL}/d/stack-logs-final?orgId=1&refresh=10s&from=now-6h&to=now`, { waitUntil: 'networkidle' });

    console.log('  - Grafana: Waiting for log entries (up to 60s)...');
    
    // Grafana 11 usa tabelas para logs. Vamos procurar por linhas de dados.
    const logRows = page.getByRole('row');
    
    await expect(async () => {
      const count = await logRows.count();
      console.log(`    - Current row count: ${count}`);
      // Geralmente tem 1 row de header, então queremos > 1
      expect(count).toBeGreaterThan(1);
    }).toPass({ timeout: 60000 });

    console.log('  - Grafana: Logs validation passed.');
  });
});
