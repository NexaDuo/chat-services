import { test, expect } from '@playwright/test';
import { requireEnv } from './helpers/creds';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '../..');

/**
 * Regression guard for issue #135.
 *
 * The live Chatwoot super-admin password (and the Grafana admin password) were
 * committed as hardcoded fallbacks across the onboarding specs and the env
 * generators, leaking real production credentials into git and its history:
 *   - `const ADMIN_PASSWORD = '<secret>'`
 *   - `process.env.ADMIN_PASSWORD || '<secret>'`
 *   - `page.fill(..., '<grafana secret>')`
 *   - a predictable `NexaDuo@YEAR-<hex>` generator pattern in scripts/generate-env.*
 *
 * This test scans the versioned specs and env-generator scripts and fails if any
 * of those shapes reappear. It prevents someone reintroducing a baked-in
 * credential (the exact regression that #135 fixed). Secrets must come only from
 * the non-versioned .env; tests must read them via requireEnv() and skip when
 * absent, never fall back to a literal.
 *
 * This runs as a pure static check (no network, no stack) so it is safe in every
 * environment, including CI.
 */

// Directories whose versioned source must stay free of baked-in credentials.
const SCAN_TARGETS = [
  path.join(REPO_ROOT, 'onboarding', 'tests'),
  path.join(REPO_ROOT, 'scripts'),
];

// This spec necessarily names the forbidden shapes, so exclude it from its own scan.
const SELF = path.basename(__filename);

const SCANNED_EXTENSIONS = new Set(['.ts', '.js', '.sh', '.mts', '.cts']);

function collectFiles(dir: string): string[] {
  if (!fs.existsSync(dir)) return [];
  const out: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === 'node_modules') continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...collectFiles(full));
    } else if (SCANNED_EXTENSIONS.has(path.extname(entry.name)) && entry.name !== SELF) {
      out.push(full);
    }
  }
  return out;
}

// Known leaked literals (must never reappear anywhere) and the predictable
// generator prefix that produced the leaked Chatwoot password.
const FORBIDDEN_LITERALS: RegExp[] = [
  // Built from fragments so this guard file does not itself contain the literal.
  new RegExp(['NexaDuo', '2026-C9E5FF39'].join('@')),
  /NexaDuo_2026_Admin/,
  /NexaDuo@2026-/, // predictable, low-entropy generator prefix (issue #135)
];

// A password/secret env var falling back to a NON-EMPTY string literal, e.g.
// `process.env.ADMIN_PASSWORD || 'secret'`. `|| ''` (empty) is allowed.
const FALLBACK_TO_LITERAL = /(?:PASSWORD|SECRET|PASSWD)[A-Za-z_]*\s*\|\|\s*['"][^'"]/i;

// A bare hardcoded password constant, e.g. `const ADMIN_PASSWORD = 'secret'`.
const BARE_PASSWORD_CONST = /const\s+[A-Za-z_]*PASSWORD[A-Za-z_]*\s*=\s*['"]/i;

test.describe('Regression: no hardcoded credentials in versioned code (issue #135)', () => {
  test('specs and env generators contain no baked-in secret or predictable fallback', () => {
    const files = SCAN_TARGETS.flatMap(collectFiles);
    expect(files.length, 'expected to scan at least a few versioned files').toBeGreaterThan(0);

    const violations: string[] = [];
    for (const file of files) {
      const rel = path.relative(REPO_ROOT, file);
      const lines = fs.readFileSync(file, 'utf8').split('\n');
      lines.forEach((line, i) => {
        const loc = `${rel}:${i + 1}`;
        for (const re of FORBIDDEN_LITERALS) {
          if (re.test(line)) violations.push(`${loc} — leaked/predictable literal (${re})`);
        }
        if (FALLBACK_TO_LITERAL.test(line)) {
          violations.push(`${loc} — password/secret falls back to a hardcoded literal`);
        }
        if (BARE_PASSWORD_CONST.test(line)) {
          violations.push(`${loc} — password assigned a hardcoded literal`);
        }
      });
    }

    expect(
      violations,
      `Hardcoded credential(s) reintroduced (issue #135). Read secrets from .env via ` +
        `requireEnv() and skip when unset:\n${violations.join('\n')}`,
    ).toEqual([]);
  });

  test('requireEnv reads the value from the environment (no literal fallback)', () => {
    const name = 'MARC_REGRESSION_PROBE_135';
    const sentinel = `probe-${Date.now()}`;
    const prev = process.env[name];
    try {
      process.env[name] = sentinel;
      expect(requireEnv(name)).toBe(sentinel);
    } finally {
      if (prev === undefined) delete process.env[name];
      else process.env[name] = prev;
    }
  });
});
