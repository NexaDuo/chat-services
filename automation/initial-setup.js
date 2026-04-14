import { chromium } from 'playwright';
import dotenv from 'dotenv';
import path from 'path';

// Load .env from root
dotenv.config({ path: path.resolve(process.cwd(), '../.env') });

const CHATWOOT_URL = process.env.CHATWOOT_FRONTEND_URL || 'http://localhost:3000';
const DIFY_URL = process.env.DIFY_CONSOLE_WEB_URL || 'http://localhost:3001';
const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'alexandre@nexaduo.com';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'NexaDuo@2025';

async function setupChatwoot() {
  console.log('Starting Chatwoot Setup...');
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();

  try {
    // Chatwoot v4.x uses /installation/onboarding for first-time setup
    await page.goto(`${CHATWOOT_URL}/installation/onboarding`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    console.log('  - Page loaded:', page.url());

    // Check if already setup (redirects to login or dashboard)
    if (page.url().includes('/login') || page.url().includes('/app/accounts')) {
      console.log('  - Chatwoot is already configured.');
      await browser.close();
      return;
    }

    // Chatwoot v4.x onboarding form uses user[name], user[company], user[email], user[password]
    await page.fill('input[name="user[name]"]', 'NexaDuo Admin');
    await page.fill('input[name="user[company]"]', 'NexaDuo');
    await page.fill('input[name="user[email]"]', ADMIN_EMAIL);
    await page.fill('input[name="user[password]"]', ADMIN_PASSWORD);

    await page.click('button[type="submit"]');

    // After setup, Chatwoot redirects to the dashboard or login
    await page.waitForURL('**/app/**', { timeout: 30000 });
    console.log('OK Chatwoot Admin created successfully!');
  } catch (err) {
    console.error('FAIL Chatwoot Setup failed:', err.message);
  } finally {
    await browser.close();
  }
}

async function setupDify() {
  console.log('Starting Dify Setup...');
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();

  try {
    await page.goto(`${DIFY_URL}/install`, { timeout: 30000 });
    console.log('  - Waiting for Dify install page to render...');

    // Wait for the form to render (React SPA). Allow the client-side redirect
    // to /signin or /apps to settle first if Dify is already configured.
    await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});
    await page.waitForSelector('input', { timeout: 30000 });

    // Check if already setup (redirects to signin or apps)
    if (page.url().includes('/signin') || page.url().includes('/apps')) {
      console.log('  - Dify is already configured.');
      await browser.close();
      return;
    }

    // Dify 1.x install page — fill fields by placeholder or label
    await page.getByPlaceholder(/email/i).fill(ADMIN_EMAIL);
    await page.getByPlaceholder(/name/i).fill('NexaDuo');

    // Password fields
    const passwordInputs = page.locator('input[type="password"]');
    const count = await passwordInputs.count();
    if (count >= 2) {
      await passwordInputs.nth(0).fill(ADMIN_PASSWORD);
      await passwordInputs.nth(1).fill(ADMIN_PASSWORD);
    } else if (count === 1) {
      await passwordInputs.nth(0).fill(ADMIN_PASSWORD);
    }

    // Submit
    const submitBtn = page.locator('button[type="submit"], button:has-text("Set up")').first();
    await submitBtn.click();

    // After submit, Dify either redirects to /signin (account just created) or /apps (auto-logged in)
    await page.waitForURL(/\/(signin|apps)/, { timeout: 30000 });
    console.log('OK Dify Admin created successfully!');
  } catch (err) {
    console.error('FAIL Dify Setup failed:', err.message);
  } finally {
    await browser.close();
  }
}

async function run() {
  console.log('--- NexaDuo Stack Automation ---');
  await setupChatwoot();
  await setupDify();
  console.log('---------------------------------');
}

run();
