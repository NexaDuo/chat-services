import { test, expect } from '@playwright/test';

/**
 * Regression test for issue #273: the Chatwoot dashboard HTML carried no
 * Open Graph tags, so the Meta Sharing Debugger reported og:image as an
 * "inferred property" and link previews of the hub URL were guessed from the
 * favicons.
 *
 * Fix: deploy/open_graph.rb (a Rack middleware mounted into chatwoot-rails)
 * inserts explicit og:* tags before </head>, and deploy/og-images/ is served
 * from the same host under /og-images/. Text and picture come from the tenant
 * that owns the host (tenants.yaml `branding:` -> tenants table -> middleware
 * GET /public/tenant-branding), with a neutral static fallback.
 *
 * Which tenant row exists differs per environment, so the assertions are on
 * presence and shape plus a real fetch of the image. Where the seed is known
 * (CI seeds the `ci-hub` tenant), EXPECTED_OG_TITLE / EXPECTED_OG_IMAGE_PATH
 * additionally prove that the values travelled the whole tenant-config path.
 *
 * The first test reads the raw HTML with the crawler's user agent, because a
 * crawler does not run JavaScript: what it sees is the server response, not
 * the DOM. The URLs must sit on the configured base URL (CHATWOOT_URL), which
 * is https behind the tunnel and plain http in the ephemeral CI stack, so the
 * scheme is compared with CHATWOOT_URL instead of being hardcoded.
 */

const CHATWOOT_URL = (process.env.CHATWOOT_URL || 'http://localhost:3000').replace(/\/+$/, '');
const CRAWLER_UA = 'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)';
const REQUIRED = [
  'og:type',
  'og:url',
  'og:title',
  'og:description',
  'og:image',
  'og:image:type',
  'og:image:width',
  'og:image:height',
];

/** Every `<meta property|name="og:...">` in the document head, in order. */
function openGraphTags(html: string): { property: string; content: string }[] {
  const head = html.split(/<\/head\s*>/i)[0];
  const tags: { property: string; content: string }[] = [];
  for (const [tag] of head.matchAll(/<meta\b[^>]*>/gi)) {
    const property = /\b(?:property|name)\s*=\s*["'](og:[^"']*)["']/i.exec(tag)?.[1];
    const content = /\bcontent\s*=\s*"([^"]*)"/i.exec(tag)?.[1] ?? /\bcontent\s*=\s*'([^']*)'/i.exec(tag)?.[1];
    if (property) tags.push({ property, content: content ?? '' });
  }
  return tags;
}

test.describe('Chatwoot Open Graph tags (#273)', () => {
  test('crawler sees each og:* tag exactly once and the og:image URL serves a raster image', async ({ request }) => {
    const origin = new URL(CHATWOOT_URL).origin;
    const response = await request.get(`${CHATWOOT_URL}/`, { headers: { 'User-Agent': CRAWLER_UA } });
    expect(response.status(), `GET ${CHATWOOT_URL}/ as the Facebook crawler`).toBe(200);
    expect(response.headers()['content-type']).toMatch(/^text\/html/);

    const html = await response.text();
    // A rewritten body with a stale Content-Length would arrive truncated.
    expect(html, 'HTML document is complete (Content-Length matches the rewritten body)').toMatch(/<\/html>\s*$/i);

    const tags = openGraphTags(html);
    const value = (property: string) => tags.filter((tag) => tag.property === property).map((tag) => tag.content);
    for (const property of REQUIRED) {
      // The bug of #273 is a count of 0; a count of 2 would be a duplicate injection.
      expect(value(property), `<meta property="${property}"> must appear exactly once in <head>`).toHaveLength(1);
      expect(value(property)[0].trim(), `${property} must not be empty`).not.toBe('');
    }

    expect(value('og:type')[0]).toBe('website');
    expect(value('og:url')[0], 'og:url is the configured public root').toBe(`${origin}/`);

    const image = new URL(value('og:image')[0]); // throws if the URL is not absolute
    expect(image.origin, 'og:image is an absolute URL on the Chatwoot public host').toBe(origin);

    // No cookies, no auth: this is what the crawler does next.
    const imageResponse = await request.get(image.href, { headers: { 'User-Agent': CRAWLER_UA }, maxRedirects: 0 });
    expect(imageResponse.status(), `GET ${image.href}`).toBe(200);
    const contentType = imageResponse.headers()['content-type'];
    // Facebook does not accept SVG.
    expect(contentType, 'og:image must be a raster image').toMatch(/^image\/(png|jpeg)/);
    expect(value('og:image:type')[0]).toBe(contentType.split(';')[0].trim());

    const bytes = await imageResponse.body();
    if (contentType.startsWith('image/png')) {
      expect(bytes.subarray(0, 8).toString('hex'), 'PNG signature').toBe('89504e470d0a1a0a');
      // The advertised size lets the crawler skip fetching the image to size it,
      // so it has to be the real size of the file being served.
      expect(value('og:image:width')[0]).toBe(String(bytes.readUInt32BE(16)));
      expect(value('og:image:height')[0]).toBe(String(bytes.readUInt32BE(20)));
    }
  });

  test('branding comes from the tenant that owns the host', async ({ request }) => {
    const expectedTitle = process.env.EXPECTED_OG_TITLE;
    const expectedImagePath = process.env.EXPECTED_OG_IMAGE_PATH;
    test.skip(!expectedTitle, 'EXPECTED_OG_TITLE not set: the tenant seed of this environment is not known to the test');
    test.setTimeout(240000);

    // chatwoot-rails caches the lookup and rechecks a host nobody owned yet
    // once a minute, and CI seeds the tenant after the stack is already up.
    await expect(async () => {
      const response = await request.get(`${CHATWOOT_URL}/`, { headers: { 'User-Agent': CRAWLER_UA } });
      const tags = openGraphTags(await response.text());
      const value = (property: string) => tags.find((tag) => tag.property === property)?.content;
      expect(value('og:title'), 'og:title is the tenant og_title from tenants.yaml').toBe(expectedTitle);
      if (expectedImagePath) {
        expect(new URL(value('og:image') ?? '').pathname, 'og:image is the tenant og_image_url').toBe(expectedImagePath);
      }
    }).toPass({ timeout: 180000, intervals: [5000] });
  });

  test('rendered page has exactly one og:image meta', async ({ page }) => {
    await page.goto(`${CHATWOOT_URL}/`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    const meta = page.locator('head meta[property="og:image"]');
    await expect(meta).toHaveCount(1);
    const content = await meta.getAttribute('content');
    expect(new URL(content ?? '').origin).toBe(new URL(CHATWOOT_URL).origin);
  });

  test('non-HTML responses are not rewritten', async ({ request }) => {
    const response = await request.get(`${CHATWOOT_URL}/api`, { headers: { 'User-Agent': CRAWLER_UA } });
    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toMatch(/^application\/json/);
    const body = await response.text();
    expect(body).not.toContain('og:');
    expect(() => JSON.parse(body), '/api must still be valid JSON').not.toThrow();
  });
});
