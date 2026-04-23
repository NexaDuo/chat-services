import { chromium } from 'playwright';
import dotenv from 'dotenv';
import path from 'path';
import { execSync } from 'child_process';

dotenv.config({ path: path.resolve(process.cwd(), '../.env') });

const CHATWOOT_URL = process.env.CHATWOOT_FRONTEND_URL || 'http://localhost:3000';
const ADMIN_EMAIL = process.env.ADMIN_EMAIL;
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD;
const CHATWOOT_LOGIN_EMAIL = process.env.CHATWOOT_ADMIN_EMAIL || ADMIN_EMAIL;
const CHATWOOT_LOGIN_PASSWORD = process.env.CHATWOOT_ADMIN_PASSWORD || ADMIN_PASSWORD;

const GCP_PROJECT_ID = process.env.GCP_PROJECT_ID || 'nexaduo-492818';
const GCP_ZONE = process.env.GCP_ZONE || 'us-central1-b';
const GCP_VM_NAME = process.env.GCP_VM_NAME || 'nexaduo-chat-services';

if (!CHATWOOT_LOGIN_EMAIL || !CHATWOOT_LOGIN_PASSWORD) {
  console.error('FATAL: Set CHATWOOT_ADMIN_EMAIL/CHATWOOT_ADMIN_PASSWORD (or ADMIN_EMAIL/ADMIN_PASSWORD) in .env.');
  process.exit(1);
}

async function login(page) {
  await page.goto(`${CHATWOOT_URL}/app/login`, { waitUntil: 'domcontentloaded', timeout: 60000 });

  const emailInput = page.locator(
    'input[placeholder*="example@" i], input[placeholder*="email" i], input[type="email"], input[name="email"], input[type="text"]'
  ).first();
  const passwordInput = page.locator(
    'input[placeholder*="password" i], input[type="password"], input[name="password"]'
  ).first();
  const submitButton = page.locator('button[type="submit"], button:has-text("Entrar"), button:has-text("Sign in"), button:has-text("Login")').first();

  await emailInput.fill(CHATWOOT_LOGIN_EMAIL);
  await passwordInput.fill(CHATWOOT_LOGIN_PASSWORD);
  await submitButton.click();

  await page.waitForTimeout(4000);
  if (page.url().includes('/app/login')) {
    const error = await page.locator('[role="alert"], .alert, .error, .form-error').first().textContent().catch(() => null);
    throw new Error(`Login failed on /app/login. ${error ? `Server message: ${error.trim()}` : 'Check CHATWOOT admin credentials in .env.'}`);
  }
  await page.waitForURL(/\/app\//, { timeout: 60000 });
}

async function openFirstConversation(page) {
  let accountId = page.url().match(/\/accounts\/(\d+)/)?.[1];
  if (!accountId) {
    await page.goto(`${CHATWOOT_URL}/app/accounts`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForLoadState('networkidle', { timeout: 30000 }).catch(() => {});
    const convHref = await page.locator('a[href*="/conversations"]').first().getAttribute('href').catch(() => null);
    accountId = convHref?.match(/\/accounts\/(\d+)/)?.[1] || null;
  }
  if (!accountId) {
    throw new Error('Could not resolve Chatwoot account id for conversations.');
  }

  await page.goto(`${CHATWOOT_URL}/app/accounts/${accountId}/conversations`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForLoadState('networkidle', { timeout: 30000 }).catch(() => {});

  const conversationItem = page.locator(
    '[data-testid="conversation-card"], [data-testid="conversation-list-item"], .conversation--item, [role="listitem"]'
  ).first();

  try {
    await conversationItem.waitFor({ state: 'visible', timeout: 30000 });
  } catch {
    throw new Error('No visible conversation found in Chatwoot. Create at least one conversation before running this smoke test.');
  }
  await conversationItem.click();
}

async function sendMessage(page, text) {
  const composer = page.locator(
    [
      'textarea[placeholder*="mensagem" i]',
      'textarea[placeholder*="message" i]',
      'textarea[data-testid*="reply"]',
      '[contenteditable="true"][role="textbox"]'
    ].join(', ')
  ).first();

  await composer.waitFor({ state: 'visible', timeout: 30000 });
  await composer.fill(text);
  await composer.press('Enter');

  // Confirma que a própria mensagem apareceu na conversa.
  await page.getByText(text, { exact: false }).first().waitFor({ state: 'visible', timeout: 30000 });
}

function checkMiddlewareLogs() {
  const cmd = [
    `gcloud compute ssh ${GCP_VM_NAME}`,
    `--zone ${GCP_ZONE}`,
    `--project ${GCP_PROJECT_ID}`,
    '--tunnel-through-iap',
    `--command 'CID=$(sudo docker ps --filter "label=coolify.service.subName=middleware" --format "{{.ID}}" | head -n1);`,
    'if [ -z "$CID" ]; then echo "middleware container not found"; exit 1; fi;',
    'sudo docker logs "$CID" --since 5m --tail 600 | grep -Ei "tenant|x-tenant-id|chatwoot|dify" || true\''
  ].join(' ');

  const output = execSync(cmd, { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  if (!output) {
    throw new Error('No middleware tenant evidence found in the last 5 minutes.');
  }

  console.log('  - Middleware log evidence found.');
}

async function run() {
  console.log('--- Chatwoot Message E2E Verification (Playwright) ---');
  console.log(`Target: ${CHATWOOT_URL}`);

  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  const messageText = `E2E smoke ${new Date().toISOString()}`;

  try {
    await login(page);
    console.log('  - Login OK');

    await openFirstConversation(page);
    console.log('  - Conversation opened');

    await sendMessage(page, messageText);
    console.log('  - Message sent and visible in UI');

    checkMiddlewareLogs();
    console.log('OK Chatwoot message flow + middleware tenant evidence verified.');
  } catch (err) {
    await page.screenshot({ path: 'chatwoot-message-smoke-fail.png', fullPage: true }).catch(() => {});
    throw err;
  } finally {
    await browser.close();
  }
}

run().catch((err) => {
  console.error(`FAIL Chatwoot message verification failed: ${err.message}`);
  process.exit(1);
});
