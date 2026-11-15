#!/usr/bin/env bash
# Guard for issue #135: no PASSWORD/SECRET/TOKEN env var may fall back to a
# hardcoded literal (`X || 'literal'`, `X ?? "literal"`) under onboarding/ or
# scripts/. Secrets come from the non-versioned root .env only.
#
# Usage:
#   test-no-hardcoded-secrets.sh            scan the tracked tree, then self-test
#   (the scan fails the script on any hit; the self-test proves the pattern
#    catches a synthetic positive and passes a synthetic clean sample)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# `|| ''` / `?? ''` (empty or <6 chars) stays allowed.
PATTERN='(PASSWORD|SECRET|TOKEN)[A-Za-z0-9_]*[[:space:]]*(\|\||\?\?)[[:space:]]*['"'"'"][^'"'"'"]{6,}['"'"'"]'
SELF="scripts/tests/test-no-hardcoded-secrets.sh"
SPEC="onboarding/tests/18-no-hardcoded-secrets.spec.ts"

fail=0

echo "== scan: tracked files under onboarding/ and scripts/"
hits=$(git grep -nIE -e "$PATTERN" -- onboarding scripts \
  ":(exclude)$SELF" ":(exclude)$SPEC" ":(exclude)onboarding/package-lock.json" || true)
if [ -n "$hits" ]; then
  # Print file:line only, never the matched text (it may be a real secret).
  echo "FAIL: hardcoded credential fallback(s) found:"
  echo "$hits" | cut -d: -f1,2
  fail=1
else
  echo "PASS: clean tree"
fi

echo "== self-test: synthetic positives must be caught"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<'EOF'
const A = process.env.ADMIN_PASSWORD || 'synthetic-value';
const B = process.env.API_TOKEN ?? "synthetic-value";
X=$(echo "${FOO_SECRET}" ) ; const C = process.env.DB_SECRET || 'abcdefg';
EOF
n=$(grep -cE -e "$PATTERN" "$tmp" || true)
if [ "$n" -ne 3 ]; then echo "FAIL: expected 3 synthetic positives, got $n"; fail=1; else echo "PASS: positives caught"; fi

echo "== self-test: synthetic negatives must pass"
cat > "$tmp" <<'EOF'
const A = process.env.ADMIN_PASSWORD || '';
const B = requireEnv('ADMIN_PASSWORD');
const C = process.env.API_TOKEN ?? 'abc';
const D = process.env.ADMIN_EMAIL || 'someone@example.com';
EOF
n=$(grep -cE -e "$PATTERN" "$tmp" || true)
if [ "$n" -ne 0 ]; then echo "FAIL: false positive on clean sample ($n)"; fail=1; else echo "PASS: clean sample ok"; fi

exit "$fail"
