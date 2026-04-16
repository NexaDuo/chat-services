import { chromium } from 'playwright';
import dotenv from 'dotenv';
import path from 'path';

// Load .env from root
dotenv.config({ path: path.resolve(process.cwd(), '../.env') });

const CHATWOOT_URL = process.env.CHATWOOT_FRONTEND_URL || 'http://localhost:3000';
const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'alexandre@nexaduo.com';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'NexaDuo@2025';

async function debugChatwoot() {
  console.log('Debugging Chatwoot Setup...');
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();

  try {
    await page.goto(`${CHATWOOT_URL}/installation/onboarding`, { waitUntil: 'networkidle', timeout: 60000 });
    console.log('  - Current URL:', page.url());

    if (page.url().includes('/login') || page.url().includes('/app/accounts')) {
      console.log('  - Chatwoot is already configured.');
      return;
    }

    await page.fill('input[name="user[name]"]', 'NexaDuo Admin');
    await page.fill('input[name="user[company]"]', 'NexaDuo');
    await page.fill('input[name="user[email]"]', ADMIN_EMAIL);
    await page.fill('input[name="user[password]"]', ADMIN_PASSWORD);

    console.log('  - Form filled. Submitting...');
    await page.click('button[type="submit"]');

    await page.waitForTimeout(5000);
    console.log('  - URL after submit:', page.url());
    
    await page.screenshot({ path: 'chatwoot-debug.png' });
    console.log('  - Screenshot saved as chatwoot-debug.png');

    await page.waitForURL('**/app/**', { timeout: 30000 });
    console.log('OK Chatwoot Admin created successfully!');
  } catch (err) {
    console.error('FAIL Chatwoot Setup failed:', err.message);
    await page.screenshot({ path: 'chatwoot-error.png' });
  } finally {
    await browser.close();
  }
}

debugChatwoot();
