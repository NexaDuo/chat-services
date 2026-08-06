import { describe, test, expect } from 'vitest';
import { decideMissingConfig } from './config-gate.js';

// Regression guards for issue #152: HANDOFF_SHARED_SECRET never reached the
// self-healing-agent container in production, so fetchConfig() silently
// degraded to detection-only forever instead of failing loud. These pin the
// gate that decides between "degrade" (CI/dev, explicit opt-in) and "fail"
// (production default) — the same function index.ts calls both when the
// secret itself is missing and when /config never returns a usable key after
// the retry loop. No Playwright coverage: this is server-side decision logic
// with no browser-observable surface (mirrors health-check-all.sh's /config
// container probe instead, per the issue's regression-test guidance).
describe('decideMissingConfig', () => {
  test('fails loud by default (production) when the escape hatch is not set', () => {
    expect(decideMissingConfig(false)).toBe('fail');
  });

  test('degrades silently only when explicitly allowed (CI/dev opt-in)', () => {
    expect(decideMissingConfig(true)).toBe('degrade');
  });
});
