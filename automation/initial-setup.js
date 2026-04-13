import { chromium } from 'playwright';
import dotenv from 'dotenv';
import path from 'path';

// Load .env from root
dotenv.config({ path: path.resolve(process.cwd(), '../.env') });

const CHATWOOT_URL = process.env.CHATWOOT_FRONTEND_URL || 'http://localhost:3000';
const DIFY_URL = process.env.DIFY_CONSOLE_WEB_URL || 'http://localhost:3001';
const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'admin@nexaduo.com';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'NexaDuo@2025';

async function setupChatwoot() {
  console.log('🚀 Starting Chatwoot Setup...');
  const browser = await chromium.launch({ headless: false }); // Headless false to see magic
  const page = await browser.newPage();

  try {
    await page.goto(`${CHATWOOT_URL}/app/setup/signup`);
    console.log('  - Waiting for Chatwoot setup page...');
    
    // Check if already setup
    if (page.url().includes('/login')) {
      console.log('  - Chatwoot is already configured.');
      await browser.close();
      return;
    }

    await page.fill('input[name="owner_name"]', 'NexaDuo Admin');
    await page.fill('input[name="email"]', ADMIN_EMAIL);
    await page.fill('input[name="password"]', ADMIN_PASSWORD);
    await page.fill('input[name="password_confirmation"]', ADMIN_PASSWORD);
    
    await page.click('button[type="submit"]');
    
    await page.waitForURL('**/app/accounts/**');
    console.log('✅ Chatwoot Admin created successfully!');
  } catch (err) {
    console.error('❌ Chatwoot Setup failed:', err.message);
  } finally {
    await browser.close();
  }
}

async function setupDify() {
  console.log('🚀 Starting Dify Setup...');
  const browser = await chromium.launch({ headless: false });
  const page = await browser.newPage();

  try {
    await page.goto(`${DIFY_URL}/install`);
    console.log('  - Waiting for Dify install page...');

    // Check if already setup
    if (page.url().includes('/signin')) {
      console.log('  - Dify is already configured.');
      await browser.close();
      return;
    }

    await page.fill('input[name="email"]', ADMIN_EMAIL);
    await page.fill('input[name="user_name"]', 'NexaDuo');
    await page.fill('input[name="password"]', ADMIN_PASSWORD);
    await page.fill('input[name="password_confirm"]', ADMIN_PASSWORD);
    
    await page.click('button[type="submit"]');
    
    await page.waitForURL('**/signin');
    console.log('✅ Dify Admin created successfully!');
  } catch (err) {
    console.error('❌ Dify Setup failed:', err.message);
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
