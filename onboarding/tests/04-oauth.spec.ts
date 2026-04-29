import { test, expect, request } from '@playwright/test';

// Validates that the Google OAuth init endpoints in Chatwoot and Dify do what
// they should: respond, redirect, and end up at accounts.google.com (not at a
// 404/400 inside our own services). Tracks issue #5.
//
// These tests run against production URLs by default (BASE_URL_CHATWOOT /
// BASE_URL_DIFY). They do NOT require admin credentials — both endpoints are
// unauthenticated entry points to the OAuth flow.
//
// Today these tests are EXPECTED TO FAIL until issue #5 is closed:
//   - Chatwoot: /omniauth/google_oauth2 returns 404 ("Not found. Authentication
//     passthru.") because the OmniAuth strategy never registers at boot.
//   - Dify: /console/api/oauth/login/google returns 400 {"error":"Invalid
//     provider"} because the social OAuth providers are not registered.
// Once those are fixed, these checks must pass.

const CHATWOOT = process.env.BASE_URL_CHATWOOT ?? 'https://chat.nexaduo.com';
const DIFY = process.env.BASE_URL_DIFY ?? 'https://dify.nexaduo.com';

test.describe('Google OAuth init endpoints', () => {
  test('Chatwoot: /auth/google_oauth2 redirects to accounts.google.com', async () => {
    // Use a request context with no automatic redirect so we can inspect the
    // redirect chain step by step. Playwright's page.goto would also work but
    // page.url() is less precise across multi-hop redirects.
    const ctx = await request.newContext({ baseURL: CHATWOOT, ignoreHTTPSErrors: false });
    const res = await ctx.get('/auth/google_oauth2', { maxRedirects: 5 });
    const finalUrl = res.url();

    // Body for diagnostics on failure.
    const body = (await res.text()).slice(0, 200);
    expect(
      finalUrl,
      `Expected redirect chain to end at accounts.google.com but got ${finalUrl}. Body: ${body}`,
    ).toMatch(/^https:\/\/accounts\.google\.com\//);
    expect(res.status(), `Final response should be 200 (Google sign-in page); got ${res.status()}`).toBe(200);

    await ctx.dispose();
  });

  test('Dify: /console/api/oauth/login/google issues a redirect to accounts.google.com', async () => {
    const ctx = await request.newContext({ baseURL: DIFY, ignoreHTTPSErrors: false });
    const res = await ctx.get('/console/api/oauth/login/google', { maxRedirects: 5 });
    const finalUrl = res.url();
    const status = res.status();
    const body = (await res.text()).slice(0, 200);

    expect(
      status,
      `Expected 200 (after following redirects to Google); got ${status}. Body: ${body}`,
    ).toBe(200);
    expect(
      finalUrl,
      `Expected redirect chain to end at accounts.google.com but got ${finalUrl}. Body: ${body}`,
    ).toMatch(/^https:\/\/accounts\.google\.com\//);

    await ctx.dispose();
  });
});
