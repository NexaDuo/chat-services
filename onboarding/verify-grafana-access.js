import { chromium } from 'playwright';
import dotenv from 'dotenv';
import path from 'path';

dotenv.config({ path: path.resolve(process.cwd(), '../.env') });

const GRAFANA_URL = process.env.GRAFANA_URL || 'https://grafana.nexaduo.com';
const GRAFANA_USER = process.env.GRAFANA_ADMIN_USER;
const GRAFANA_PASSWORD = process.env.GRAFANA_ADMIN_PASSWORD;

async function resolveWithDoh(hostname) {
  const resp = await fetch(`https://cloudflare-dns.com/dns-query?name=${hostname}&type=A`, {
    headers: { accept: 'application/dns-json' }
  });
  if (!resp.ok) return null;
  const data = await resp.json();
  const firstA = (data.Answer || []).find((a) => a.type === 1 && a.data);
  return firstA?.data || null;
}

if (!GRAFANA_USER || !GRAFANA_PASSWORD) {
  console.error('FATAL: Set GRAFANA_ADMIN_USER and GRAFANA_ADMIN_PASSWORD in .env.');
  process.exit(1);
}

async function run() {
  console.log('--- Grafana Public Access Verification (Playwright) ---');
  console.log(`Target: ${GRAFANA_URL}`);

  let browser = await chromium.launch({ headless: true });
  let page = await browser.newPage();

  try {
    let response;
    try {
      response = await page.goto(`${GRAFANA_URL}/login`, {
        waitUntil: 'domcontentloaded',
        timeout: 60000
      });
    } catch (err) {
      if (!String(err.message).includes('ERR_NAME_NOT_RESOLVED')) {
        throw err;
      }
      const hostname = new URL(GRAFANA_URL).hostname;
      const resolvedIp = await resolveWithDoh(hostname);
      if (!resolvedIp) {
        throw new Error(`DNS local falhou para ${hostname} e fallback DoH não encontrou A record.`);
      }
      console.log(`  - DNS local não resolveu ${hostname}; usando fallback DoH ${resolvedIp}`);
      await browser.close();
      browser = await chromium.launch({
        headless: true,
        args: [`--host-resolver-rules=MAP ${hostname} ${resolvedIp}`]
      });
      page = await browser.newPage();
      response = await page.goto(`${GRAFANA_URL}/login`, {
        waitUntil: 'domcontentloaded',
        timeout: 60000
      });
    }

    const status = response?.status() ?? 0;
    console.log(`  - /login HTTP ${status}`);
    if (status !== 200) {
      throw new Error(`Grafana /login returned HTTP ${status}`);
    }

    await page.locator('input[name="user"], input[type="text"]').first().fill(GRAFANA_USER);
    await page.locator('input[name="password"], input[type="password"]').first().fill(GRAFANA_PASSWORD);
    await page.locator('button[type="submit"], button:has-text("Log in"), button:has-text("Entrar")').first().click();

    await page.waitForURL(url => !url.pathname.includes('/login'), { timeout: 60000 });
    console.log(`  - Login OK (${page.url()})`);

    console.log('OK Grafana public access + authentication verified.');
  } catch (err) {
    await page.screenshot({ path: 'grafana-access-fail.png', fullPage: true }).catch(() => {});
    throw err;
  } finally {
    await browser.close();
  }
}

run().catch((err) => {
  console.error(`FAIL Grafana verification failed: ${err.message}`);
  process.exit(1);
});
