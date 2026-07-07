import { test } from '@playwright/test';

/**
 * Reads a required credential from the environment.
 *
 * Returns the value of `name`, or skips the current test (gracefully, with a
 * clear reason) when the variable is unset or empty. It never falls back to a
 * hardcoded literal.
 *
 * Regression guard for issue #135: the Chatwoot super-admin password used to be
 * committed as a `process.env.X || '<secret>'` fallback (and as bare `const X =
 * '<secret>'`) across these specs, leaking a live production credential into git
 * and its history. Secrets must come from the non-versioned `.env` only; when a
 * secret is absent the test must skip, not authenticate with a baked-in value.
 */
export function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    test.skip(
      true,
      `${name} not set — refusing to fall back to a hardcoded secret (issue #135). ` +
        `Set ${name} in the non-versioned .env to run this test.`,
    );
  }
  // test.skip(true, ...) throws to skip, so execution never reaches here when unset.
  return value as string;
}
