import { test, expect } from '@playwright/test';
import { requireEnv } from './helpers/creds';

/**
 * Regression test for the Chatwoot CSRF / X-Forwarded-Proto bug.
 *
 * Bug: Cloudflare edge (HTTPS) -> cloudflared tunnel -> coolify-proxy (Traefik
 * http entrypoint :80) -> chatwoot-rails:3000. Traefik's http entrypoint has no
 * forwardedHeaders.trustedIPs/insecure, so it did NOT trust cloudflared's
 * inbound `X-Forwarded-Proto: https` and forwarded `http` to Chatwoot. Rails 7.1
 * then computed `request.base_url = http://chat.nexaduo.com`, and its CSRF
 * forgery_protection_origin_check rejected the browser `Origin: https://...`
 * header with:
 *   ActionController::InvalidAuthenticityToken
 *   (HTTP Origin header (https://chat.nexaduo.com) didn't match
 *    request.base_url (http://chat.nexaduo.com))
 * -> HTTP 422 on EVERY non-GET form/XHR POST (login, super_admin user update,
 *    settings, etc.).
 *
 * Fix: scripts/refresh-coolify-routes.sh attaches a Traefik `headers` middleware
 * (nexaduo-force-https-proto) with customRequestHeaders X-Forwarded-Proto: https
 * to the chatwoot router (and the other tunneled app routers). This makes Rails
 * see request.base_url = https://... so the origin check passes. It sets a
 * request header only and issues NO redirects, so it cannot reintroduce a
 * Cloudflare SSL redirect loop (cf. AGENTS.md "Cloudflare SSL Loops").
 *
 * This test logs into Chatwoot (a CSRF-protected POST flow) and asserts that no
 * state-changing request comes back 422. A 422 on a POST/PATCH/PUT here is the
 * signature of the origin/base_url mismatch returning.
 */

const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'alexandre@nexaduo.com';
const CHATWOOT_URL = process.env.CHATWOOT_URL || 'https://chat.nexaduo.com';

test.describe('Chatwoot CSRF / X-Forwarded-Proto regression', () => {
  test('CSRF-protected POSTs are not rejected with 422 (origin/base_url mismatch)', async ({ page }) => {
    test.setTimeout(120000);

    // Capture any state-changing request that comes back 422. Under the bug,
    // Rails returns 422 for the origin/base_url mismatch on every such request.
    const rejected: string[] = [];
    page.on('response', (response) => {
      const req = response.request();
      const method = req.method();
      const status = response.status();
      if (status === 422 && ['POST', 'PATCH', 'PUT', 'DELETE'].includes(method)) {
        rejected.push(`[HTTP 422] ${method} ${response.url()}`);
      }
    });

    console.log(`- Navigating to ${CHATWOOT_URL}/app/login...`);
    await page.goto(`${CHATWOOT_URL}/app/login`, { waitUntil: 'domcontentloaded', timeout: 60000 });

    // If a session is already active we'll be redirected to the dashboard.
    const dashboard = page.locator('.sidebar, .top-bar, .user-profile, .brand-name');
    const emailInput = page
      .locator('input[name="email_address"], input[name="email"], input[type="email"]')
      .first();

    await Promise.race([
      emailInput.waitFor({ state: 'visible', timeout: 30000 }).catch(() => {}),
      dashboard.first().waitFor({ state: 'visible', timeout: 30000 }).catch(() => {}),
    ]);

    const alreadyLoggedIn =
      page.url().includes('/app/accounts') ||
      page.url().includes('/app/dashboard') ||
      (await dashboard.first().isVisible().catch(() => false));

    if (!alreadyLoggedIn) {
      // Login is required to exercise the CSRF-protected POST; without a real
      // password we skip rather than fall back to a hardcoded secret (issue #135).
      const adminPassword = requireEnv('ADMIN_PASSWORD');
      console.log('- Submitting login (CSRF-protected POST to the auth endpoint)...');
      await emailInput.fill(ADMIN_EMAIL);
      await page
        .locator('input[name="password"], input[type="password"]')
        .first()
        .fill(adminPassword);

      // The submit triggers the CSRF-protected sign-in request. We wait for it
      // explicitly so we observe its status even if it fails.
      const [authResponse] = await Promise.all([
        page
          .waitForResponse(
            (r) =>
              ['POST', 'PATCH', 'PUT'].includes(r.request().method()) &&
              /\/(auth\/sign_in|sign_in|session)/i.test(r.url()),
            { timeout: 30000 },
          )
          .catch(() => null),
        page.locator('button[type="submit"]').first().click(),
      ]);

      if (authResponse) {
        console.log(`- Auth request: ${authResponse.request().method()} ${authResponse.url()} -> ${authResponse.status()}`);
        // The exact assertion guarding the bug: the auth POST must NOT 422.
        expect(
          authResponse.status(),
          `Chatwoot auth POST returned 422 -> origin/base_url mismatch regression: ${authResponse.url()}`,
        ).not.toBe(422);
      }

      // Allow the post-login navigation / follow-up requests to settle.
      await page.waitForLoadState('networkidle', { timeout: 30000 }).catch(() => {});
    } else {
      console.log('- Active Chatwoot session detected; verifying no 422 on session bootstrap requests.');
      await page.waitForTimeout(5000);
    }

    // No state-changing request observed during the flow may be a 422. A 422 here
    // is the signature of the InvalidAuthenticityToken origin/base_url mismatch.
    expect(
      rejected,
      `Detected HTTP 422 on CSRF-protected request(s) (X-Forwarded-Proto/origin regression):\n${rejected.join('\n')}`,
    ).toEqual([]);
  });
});
