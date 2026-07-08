import { test, expect } from '@playwright/test';
import { requireEnv } from './helpers/creds';

/**
 * Regression test for issue #95 — Chatwoot /super_admin CSRF 422.
 *
 * Bug: Cloudflare edge (HTTPS) -> cloudflared tunnel -> Traefik (http entrypoint)
 * -> chatwoot-rails. TLS terminates at the edge, so Rails saw the request as http
 * and computed `request.base_url = http://chat.nexaduo.com`, while the browser
 * sends `Origin: https://chat.nexaduo.com`. Rails' CSRF `verified_request?` origin
 * check failed on the scheme mismatch and returned HTTP 422 (`unverified_request`)
 * on EVERY state-changing request in the server-rendered /super_admin panel — the
 * exact symptom the SRE audit captured on `PATCH /super_admin/users/3`.
 *
 * Fix (issue #95): deploy/assume_ssl.rb sets `config.assume_ssl = true` (wired from
 * RAILS_ASSUME_SSL in deploy/docker-compose.chatwoot.yml). ActionDispatch::AssumeSSL
 * normalizes the rack env to https, so `base_url` is https and the origin check
 * passes. assume_ssl inserts a middleware only and issues NO redirect, so it cannot
 * reintroduce the Cloudflare FORCE_SSL redirect loop (cf. AGENTS.md "Cloudflare SSL
 * loops"); FORCE_SSL stays false.
 *
 * This test signs into the Rails-rendered /super_admin panel (a CSRF-protected POST)
 * and saves a user edit (a CSRF-protected PATCH — the exact failing verb/route) and
 * asserts neither comes back 422. A 422 on these is the signature of the
 * origin/base_url scheme mismatch regressing.
 *
 * Not in the CI merge gate (stack-compose-playwright.yml runs only 01 + 07); this
 * runs under `npm run test:all` against the live tunnel URL. It skips gracefully
 * when no SuperAdmin is reachable/creds are absent (e.g. an ephemeral stack with no
 * seeded super admin) so it never spuriously fails those environments.
 */

const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'alexandre@nexaduo.com';
const CHATWOOT_URL = process.env.CHATWOOT_URL || 'https://chat.nexaduo.com';

test.describe('Chatwoot /super_admin CSRF regression (issue #95)', () => {
  test('super_admin sign-in POST and user-edit PATCH are not rejected with 422', async ({ page }) => {
    test.setTimeout(120000);

    // Any state-changing super_admin request returning 422 is the bug's signature.
    const rejected: string[] = [];
    page.on('response', (response) => {
      const req = response.request();
      const method = req.method();
      if (
        response.status() === 422 &&
        ['POST', 'PATCH', 'PUT', 'DELETE'].includes(method) &&
        /\/super_admin(\/|$)/.test(response.url())
      ) {
        rejected.push(`[HTTP 422] ${method} ${response.url()}`);
      }
    });

    console.log(`- Navigating to ${CHATWOOT_URL}/super_admin/sign_in ...`);
    await page.goto(`${CHATWOOT_URL}/super_admin/sign_in`, {
      waitUntil: 'domcontentloaded',
      timeout: 60000,
    });

    const emailInput = page
      .locator('input[name="super_admin[email]"], input[type="email"], input[name*="email"]')
      .first();

    const hasLoginForm = await emailInput.isVisible({ timeout: 20000 }).catch(() => false);
    if (!hasLoginForm) {
      test.skip(true, 'No reachable /super_admin sign-in form (no seeded SuperAdmin in this env).');
      return;
    }

    // Sign-in needs a real password; without one we skip rather than fall back
    // to a hardcoded secret (issue #135).
    const ADMIN_PASSWORD = requireEnv('ADMIN_PASSWORD');
    console.log('- Submitting super_admin sign-in (CSRF-protected POST to /super_admin/sign_in)...');
    await emailInput.fill(ADMIN_EMAIL);
    await page
      .locator('input[name="super_admin[password]"], input[type="password"], input[name*="password"]')
      .first()
      .fill(ADMIN_PASSWORD);

    const [signInResponse] = await Promise.all([
      page
        .waitForResponse(
          (r) =>
            r.request().method() === 'POST' && /\/super_admin\/sign_in/.test(r.url()),
          { timeout: 30000 },
        )
        .catch(() => null),
      page.locator('button[type="submit"], input[type="submit"]').first().click(),
    ]);

    if (signInResponse) {
      console.log(`- Sign-in: POST ${signInResponse.url()} -> ${signInResponse.status()}`);
      // Core guard: the sign-in POST must NOT 422 (origin/base_url mismatch).
      expect(
        signInResponse.status(),
        `super_admin sign-in POST returned 422 -> CSRF origin/base_url scheme mismatch regressed (#95): ${signInResponse.url()}`,
      ).not.toBe(422);
    }

    await page.waitForLoadState('networkidle', { timeout: 30000 }).catch(() => {});

    // If auth did not land us in the panel (wrong creds / no super admin), skip the
    // PATCH leg — the sign-in leg above already guards the CSRF origin check.
    const loggedIntoPanel =
      /\/super_admin(\/|$)/.test(page.url()) &&
      !/sign_in/.test(page.url());
    if (!loggedIntoPanel) {
      test.skip(true, 'super_admin sign-in did not reach the panel (creds unavailable in this env).');
      return;
    }

    // Exercise the exact failing verb/route from the audit: a user-edit PATCH.
    console.log('- Opening a super_admin user edit form to exercise a CSRF-protected PATCH...');
    await page.goto(`${CHATWOOT_URL}/super_admin/users`, {
      waitUntil: 'domcontentloaded',
      timeout: 60000,
    });

    const editLink = page.locator('a[href*="/super_admin/users/"][href$="/edit"]').first();
    const hasEdit = await editLink.isVisible({ timeout: 15000 }).catch(() => false);
    if (!hasEdit) {
      console.log('- No editable user row found; sign-in POST guard is sufficient for this run.');
    } else {
      await editLink.click();
      await page.waitForLoadState('domcontentloaded', { timeout: 30000 }).catch(() => {});

      // Resubmitting the edit form unchanged still triggers the CSRF check on the
      // PATCH without mutating data.
      const [patchResponse] = await Promise.all([
        page
          .waitForResponse(
            (r) =>
              ['PATCH', 'PUT', 'POST'].includes(r.request().method()) &&
              /\/super_admin\/users\/\d+/.test(r.url()),
            { timeout: 30000 },
          )
          .catch(() => null),
        page.locator('form button[type="submit"], form input[type="submit"]').first().click(),
      ]);

      if (patchResponse) {
        console.log(`- Save: ${patchResponse.request().method()} ${patchResponse.url()} -> ${patchResponse.status()}`);
        expect(
          patchResponse.status(),
          `super_admin user-save PATCH returned 422 -> CSRF origin/base_url scheme mismatch regressed (#95): ${patchResponse.url()}`,
        ).not.toBe(422);
      }
    }

    // No super_admin state-changing request may be a 422.
    expect(
      rejected,
      `Detected HTTP 422 on /super_admin CSRF-protected request(s) (issue #95 regression):\n${rejected.join('\n')}`,
    ).toEqual([]);
  });
});
