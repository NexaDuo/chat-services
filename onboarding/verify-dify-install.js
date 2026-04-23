import { chromium } from 'playwright';
import dotenv from 'dotenv';
import path from 'path';

dotenv.config({ path: path.resolve(process.cwd(), '../.env') });

const DIFY_URL = process.env.DIFY_CONSOLE_WEB_URL || 'http://localhost:3001';

async function run() {
  console.log('--- Dify Install Verification (Playwright) ---');
  console.log(`Target: ${DIFY_URL}`);

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  const page = await context.newPage();

  try {
    const installResponse = await page.goto(`${DIFY_URL}/install`, {
      waitUntil: 'domcontentloaded',
      timeout: 60000
    });

    if (!installResponse) {
      throw new Error('No HTTP response received for /install');
    }

    const installStatus = installResponse.status();
    console.log(`  - /install HTTP ${installStatus}`);
    if (installStatus >= 500) {
      throw new Error(`/install returned ${installStatus}`);
    }

    await page.waitForLoadState('networkidle', { timeout: 30000 }).catch(() => {});
    console.log(`  - Final URL: ${page.url()}`);

    const setupResponse = await context.request.get(`${DIFY_URL}/console/api/setup`, {
      timeout: 30000
    });

    console.log(`  - /console/api/setup HTTP ${setupResponse.status()}`);
    if (setupResponse.status() !== 200) {
      throw new Error(`/console/api/setup returned ${setupResponse.status()}`);
    }

    const setupPayload = await setupResponse.json();
    console.log(`  - setup step: ${setupPayload.step}`);
    console.log('OK Dify install route + setup API are healthy.');
  } finally {
    await browser.close();
  }
}

run().catch((err) => {
  console.error(`FAIL Dify install verification failed: ${err.message}`);
  process.exit(1);
});

