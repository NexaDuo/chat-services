import { test, expect } from '@playwright/test';

const CHATWOOT_URL = process.env.CHATWOOT_URL || 'http://localhost:3000';
const DIFY_URL = process.env.DIFY_URL || 'http://localhost:3001';

test.describe('Google OAuth init endpoints', () => {
  
  test('Chatwoot: /auth/google_oauth2 redirects to accounts.google.com', async ({ browser }) => {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    
    console.log(`Checking Chatwoot OAuth at ${CHATWOOT_URL}/auth/google_oauth2...`);
    const response = await page.goto(`${CHATWOOT_URL}/auth/google_oauth2`);
    
    // In Chatwoot, this often leads directly to accounts.google.com
    const finalUrl = page.url();
    const res = await response;
    const body = await res?.text() || '';
    
    expect(
      finalUrl, 
      `Expected redirect chain to end at accounts.google.com but got ${finalUrl}. Body: ${body}`
    ).toMatch(/^https:\/\/accounts\.google\.com\//);
    expect(res?.status(), `Final response should be 200 (Google sign-in page); got ${res?.status()}`).toBe(200);

    await ctx.dispose();
  });

  test('Dify: /console/api/oauth/login/google issues a redirect to accounts.google.com', async ({ browser }) => {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    
    console.log(`Checking Dify OAuth at ${DIFY_URL}/console/api/oauth/login/google...`);
    const response = await page.goto(`${DIFY_URL}/console/api/oauth/login/google`);
    
    const finalUrl = page.url();
    const res = await response;
    const status = res?.status();
    const body = await res?.text() || '';

    expect(
      status,
      `Expected 200 (after following redirects to Google); got ${status}. Body: ${body}`
    ).toBe(200);
    expect(
      finalUrl,
      `Expected redirect chain to end at accounts.google.com but got ${finalUrl}. Body: ${body}`
    ).toMatch(/^https:\/\/accounts\.google\.com\//);

    await ctx.dispose();
  });
});
