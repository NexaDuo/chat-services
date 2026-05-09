import { test, expect } from '@playwright/test';

const ADMIN_EMAIL = 'alexandre@nexaduo.com';
const ADMIN_PASSWORD = 'NexaDuo@2026-C9E5FF39';
const COOLIFY_URL = 'https://coolify.nexaduo.com';

test('Coolify Realtime Service Connection', async ({ page }) => {
  test.setTimeout(90000);
  
  const consoleErrors: string[] = [];
  const realtimeErrorPattern = /could not connect to its real-time service/i;

  page.on('console', msg => {
    const text = msg.text();
    // We also want to see successful pusher connection if it logs anything
    if (text.includes('Pusher') || text.includes('Socket')) {
        console.log(`[DEBUG CONSOLE]: ${text}`);
    }
    if (realtimeErrorPattern.test(text)) {
      console.log(`[DETECTED REALTIME ERROR]: ${text}`);
      consoleErrors.push(text);
    }
  });

  page.on('pageerror', err => {
    if (realtimeErrorPattern.test(err.message)) {
      consoleErrors.push(err.message);
    }
  });

  console.log(`- Navigating to ${COOLIFY_URL}/login...`);
  await page.goto(`${COOLIFY_URL}/login`, { waitUntil: 'load' });

  if (page.url().includes('/login')) {
      console.log('- Filling login form...');
      await page.fill('input[name="email"]', ADMIN_EMAIL);
      await page.fill('input[name="password"]', ADMIN_PASSWORD);
      await page.click('button[type="submit"]');
  }

  console.log('- Waiting for dashboard (up to 30s)...');
  await page.waitForURL(COOLIFY_URL + '/', { timeout: 30000 });
  
  // Ensure we see something from the real dashboard
  await expect(page.getByText(/Love Coolify/i).or(page.getByText(/Dashboard/i)).first()).toBeVisible({ timeout: 15000 });

  console.log('- Monitoring console for 20s to ensure no WebSocket crashes...');
  await page.waitForTimeout(20000);

  console.log(`- Total realtime errors detected: ${consoleErrors.length}`);
  expect(consoleErrors, 'Coolify realtime service error detected in console!').toHaveLength(0);
  
  console.log('OK Realtime service is confirmed healthy via Playwright.');
});
