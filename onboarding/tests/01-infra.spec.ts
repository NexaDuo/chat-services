import { test, expect } from '@playwright/test';

const CHATWOOT_URL = process.env.CHATWOOT_URL || 'http://localhost:3000';
const DIFY_URL = process.env.DIFY_URL || 'http://localhost:3001';
const DIFY_API_URL = process.env.DIFY_API_URL || DIFY_URL; // Fallback to DIFY_URL if API_URL not set
const GRAFANA_URL = process.env.GRAFANA_URL || 'http://localhost:3002';
const EVOLUTION_URL = process.env.EVOLUTION_URL || 'http://localhost:8080';
const MIDDLEWARE_URL = process.env.MIDDLEWARE_URL || 'http://localhost:4000';

test.describe('Infrastructure Health', () => {
  const targets = [
    { name: 'Chatwoot', url: CHATWOOT_URL, path: '/' },
    { name: 'Dify Web', url: DIFY_URL, path: '/signin' },
    { name: 'Dify API', url: DIFY_API_URL, path: '/console/api/setup' },
    { name: 'Grafana', url: GRAFANA_URL, path: '/api/health' }
  ];

  for (const target of targets) {
    test(`${target.name} should be reachable`, async ({ request }) => {
      const response = await request.get(`${target.url}${target.path}`);
      expect(response.ok(), `${target.name} at ${target.url}${target.path} failed with status ${response.status()}`).toBeTruthy();
    });
  }
});

// Regression guard for the 2026-06-30 WSL-restart edge incident (#116) and the
// observability restore (#113). After the host restart the edge returned 502
// (proxy/grafana never came back) and, after a naive recreate, 404 (Traefik with
// only the Docker provider discovered 0 routers). Grafana specifically Exit-128'd
// on a host port collision (3002 taken by an unrelated stack) — fixed by dropping
// grafana's host port publish and routing purely via Traefik on the tunnel.
//
// This asserts the root path of every public *.nexaduo.com host is served
// through the edge/tunnel with NEITHER a 5xx (proxy/backend down) NOR a 404
// (missing route) — the two exact failure modes of that incident. It only runs
// against the real tunnel URLs (skipped when the *_URL envs are still localhost),
// so it is a no-op in the ephemeral CI stack and meaningful under
// `scripts/run-stack.sh validate`.
test.describe('Edge routing regression (#113/#116) — no 502/404 on public hosts', () => {
  // Path per host that has a real route behind the edge (mirrors the smoke in
  // scripts/run-stack.sh validate). Middleware only serves /health at the edge —
  // its "/" is a 404 by design, so probing "/" there would be a false positive.
  const edgeHosts = [
    { name: 'Chatwoot', url: CHATWOOT_URL, path: '/' },
    { name: 'Dify', url: DIFY_URL, path: '/' },
    // Dify API specifically (issue #41): the "/" probe above hits dify-WEB
    // (Traefik priority 10). The #41 failure is dify-API — a gunicorn master that
    // bound :5001 with no workers, so the edge returns 502 on the /console/api
    // route (priority 20) while dify-web stays fine. Probe /console/api/setup so
    // the worker-less state is caught at the edge, not just dify-web being up.
    { name: 'Dify API', url: DIFY_API_URL, path: '/console/api/setup' },
    { name: 'Evolution', url: EVOLUTION_URL, path: '/' },
    { name: 'Middleware', url: MIDDLEWARE_URL, path: '/health' },
    { name: 'Grafana', url: GRAFANA_URL, path: '/' },
  ];
  for (const host of edgeHosts) {
    const isTunnel = /^https:\/\/[a-z-]+\.nexaduo\.com/.test(host.url);
    test(`${host.name} edge returns non-5xx / non-404`, async ({ request }) => {
      test.skip(!isTunnel, `${host.name} URL is not a tunnel URL (${host.url}) — edge check only runs against *.nexaduo.com`);
      const response = await request.get(`${host.url}${host.path}`, { maxRedirects: 0 });
      const status = response.status();
      expect(status, `${host.name} edge (${host.url}${host.path}) returned ${status} — 5xx means proxy/backend down (#116), 404 means missing Traefik route`).toBeLessThan(500);
      expect(status, `${host.name} edge (${host.url}${host.path}) returned 404 — Traefik discovered no route for this host (#116)`).not.toBe(404);
    });
  }
});
