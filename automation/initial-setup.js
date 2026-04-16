import { chromium } from 'playwright';
import dotenv from 'dotenv';
import path from 'path';

// Load .env from root
dotenv.config({ path: path.resolve(process.cwd(), '../.env') });

const CHATWOOT_URL = 'http://localhost:3000';
const DIFY_URL = 'http://localhost:3001';
const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'alexandre@nexaduo.com';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'NexaDuo@2025';

async function setupChatwoot() {
  console.log('Starting Chatwoot Setup...');
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();

  try {
    await page.goto(`${CHATWOOT_URL}/installation/onboarding`, { waitUntil: 'networkidle', timeout: 90000 });
    console.log('  - Page loaded:', page.url());

    if (page.url().includes('/login') || page.url().includes('/app/accounts')) {
      console.log('  - Chatwoot is already configured.');
      await browser.close();
      return;
    }

    await page.fill('input[name="user[name]"]', 'NexaDuo Admin');
    await page.fill('input[name="user[company]"]', 'NexaDuo');
    await page.fill('input[name="user[email]"]', ADMIN_EMAIL);
    await page.fill('input[name="user[password]"]', ADMIN_PASSWORD);

    console.log('  - Submitting Chatwoot form...');
    await page.click('button[type="submit"]');

    // Wait to see if we get a validation error
    await page.waitForTimeout(5000);
    
    const errorDiv = page.locator('xpath=/html/body/div/main/section[2]/div/form/div/div[1]');
    if (await errorDiv.isVisible()) {
      const errorText = await errorDiv.innerText();
      console.error('  - Chatwoot Validation Error detected:', errorText.trim());
    }

    console.log('  - Current URL after submit:', page.url());

    // Chatwoot v4.x may take a while to initialize the DB and redirect
    // We wait for any URL change that suggests success
    await page.waitForURL(/\/(app|login|dashboard|accounts)/, { timeout: 30000 });
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
    await page.goto(`${DIFY_URL}/install`, { timeout: 60000 });
    console.log('  - Waiting for Dify install page to render...');
    await page.waitForLoadState('networkidle', { timeout: 30000 }).catch(() => {});
    
    if (page.url().includes('/signin') || page.url().includes('/apps')) {
      console.log('  - Dify is already configured.');
      await browser.close();
      return;
    }

    await page.waitForSelector('input', { timeout: 60000 });
    await page.getByPlaceholder(/email/i).fill(ADMIN_EMAIL);
    await page.getByPlaceholder(/name/i).fill('NexaDuo');

    const passwordInputs = page.locator('input[type="password"]');
    if (await passwordInputs.count() >= 2) {
      await passwordInputs.nth(0).fill(ADMIN_PASSWORD);
      await passwordInputs.nth(1).fill(ADMIN_PASSWORD);
    } else {
      await passwordInputs.nth(0).fill(ADMIN_PASSWORD);
    }

    const submitBtn = page.locator('button[type="submit"], button:has-text("Set up")').first();
    await submitBtn.click();

    await page.waitForURL(/\/(signin|apps)/, { timeout: 60000 });
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
