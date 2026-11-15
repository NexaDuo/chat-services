#!/usr/bin/env bash
# Authoritative guard for issue #135: no credential may be hardcoded in tracked
# files. Runs in the required `self-healing` job of unit-tests.yml.
#
# Checks (all over `git grep`, i.e. tracked files only):
#   1. Shape scan: a PASSWORD/PASSWD/SECRET/TOKEN/*_KEY variable that falls back
#      to, or is assigned, a non-placeholder literal. Shapes covered:
#        JS/TS  X || 'lit'   X ?? "lit"   process.env['X'] || `lit`
#        any    const|let|var|export X = 'lit'   (also bare X='lit', py/sh)
#        shell  ${X:-lit}  ${X:=lit}  ${X-lit}
#        python os.environ.get('X', 'lit')  os.getenv("X", 'lit')  X or 'lit'
#        env    X=literal  (unquoted, whole line, KEY=VALUE style files)
#      Names are matched case-insensitively. Not covered (documented gap):
#      a fallback whose literal sits on the line after the operator.
#      Placeholders (changeme, example, your..., <...>, ${...}, empty or
#      shorter than 6 chars) are not flagged.
#   2. Generator prefix: the predictable low-entropy password prefix that
#      produced the leaked Chatwoot password.
#   3. Leaked-value hashes: every token of every tracked file is hashed and
#      compared to scripts/tests/leaked-secret-hashes.txt (sha256 only; the
#      values themselves are never committed).
#
# Output is file:line only; matched text is never printed (it may be a secret).
# Exclusions are by exact repo-relative path only; see EXCLUDES and ALLOWLIST.
#
# Fail-closed: a git/PCRE error (grep status > 1) or running outside a git work
# tree fails the script. The self-test builds a temp git repo and runs the same
# scan function over it, with fixtures assembled at runtime (no committed
# credential-shaped literal; this file scans itself).
set -uo pipefail
export GIT_CONFIG_NOSYSTEM=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# Exact-path exclusions (pathspecs), each justified:
#  - lockfiles hold integrity hashes and registry tokens-shaped strings, no creds
#  - docs/superpowers/plans: historical agent plan snippets (mock tokens, gcloud
#    secret names). Still covered by the leaked-value hash scan.
EXCLUDES=(
  ':(exclude)docs/superpowers/plans'
  ':(exclude)onboarding/package-lock.json'
  ':(exclude)middleware/package-lock.json'
  ':(exclude)agents/self-healing/package-lock.json'
  ':(exclude)edge/cloudflare-worker/pnpm-lock.yaml'
)
# Narrow allowlist: lines of `<repo-relative path>:<ERE matched against the hit line>`.
# Empty on purpose; add an entry only for a reviewed, non-secret literal.
ALLOWLIST_FILE="scripts/tests/secret-guard-allowlist.txt"

Q=$'[\'"`]'
NOTQ=$'[^\'"`]'
NAME='(?<![-A-Za-z0-9_])[A-Za-z0-9_]*(?:PASSWORD|PASSWD|SECRET|TOKEN|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|AUTH_?KEY|SIGNING_?KEY|ENCRYPTION_?KEY)[A-Za-z0-9_]*'
PH='(?!\$|<|\{|%|changeme|change[-_]me|example|placeholder|your|xxx|dummy|replace|redacted|none|null|true|false|\*)'
LIT="${Q}${PH}"$'(?![^\'"`]*\\$[({])'"${NOTQ}{6,}${Q}"
P_FALLBACK="${NAME}"$'[\'"\\])\\]]*\\s*(?:\\|\\||\\?\\?|\\bor\\b)\\s*'"${LIT}"
P_ASSIGN="${NAME}"$'\\s*(?<![=!<>])=(?!=)\\s*'"${LIT}"
P_SHELLDEF=$'\\$\\{'"${NAME}"$':?[-=]'"${PH}"$'[^}]{6,}\\}'
P_PYENV=$'(?:environ\\.get|getenv)\\(\\s*'"${Q}${NAME}${Q}"$'\\s*,\\s*'"${LIT}"
P_ENVLINE="^\\s*(?:export\\s+)?${NAME}="$'(?!\\$|<)'"${PH}"$'[^\\s\'"`$#]{6,}\\s*(?:#.*)?$'
P_PREFIX='NexaDuo[@]2026-'

# scan_tree <dir>: prints "path:line" for each violation; returns 0 clean, 1 hits, 2 error.
scan_tree() {
  local dir="$1" rc=0 out
  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: $dir is not a git work tree (guard cannot run)" >&2
    return 2
  fi
  out=$(git -C "$dir" grep -nIiP \
    -e "$P_FALLBACK" -e "$P_ASSIGN" -e "$P_SHELLDEF" -e "$P_PYENV" -e "$P_ENVLINE" -e "$P_PREFIX" \
    -- . "${EXCLUDES[@]}" 2>/dev/null) || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "ERROR: git grep failed with status $rc (guard cannot run)" >&2
    return 2
  fi
  [ "$rc" -eq 1 ] && return 0
  local hits="" line loc pat allow="$dir/$ALLOWLIST_FILE"
  while IFS= read -r line; do
    loc="${line%%:*}:$(printf %s "$line" | cut -d: -f2)"
    if [ -f "$allow" ]; then
      local skip=0
      while IFS= read -r pat; do
        case "$pat" in ''|'#'*) continue ;; esac
        if [ "${pat%%:*}" = "${line%%:*}" ] && printf %s "$line" | grep -qE -e "${pat#*:}"; then skip=1; break; fi
      done < "$allow"
      [ "$skip" -eq 1 ] && continue
    fi
    hits+="$loc"$'\n'
  done <<< "$out"
  [ -z "$hits" ] && return 0
  printf %s "$hits"
  return 1
}

# scan_hashes <dir>: leaked-value hash check; prints file names only.
scan_hashes() {
  python3 -I "$HERE/leaked-hash-scan.py" "$1" "$HERE/leaked-secret-hashes.txt"
}

fail=0

echo "== scan: tracked tree ($ROOT)"
out=$(scan_tree "$ROOT"); rc=$?
case "$rc" in
  0) echo "PASS: no hardcoded credential shapes" ;;
  1) echo "FAIL: hardcoded credential shape(s) at (file:line):"; printf '%s\n' "$out"; fail=1 ;;
  *) fail=1 ;;
esac

echo "== scan: leaked-value hashes"
out=$(scan_hashes "$ROOT"); rc=$?
case "$rc" in
  0) echo "PASS: no leaked value found" ;;
  1) echo "FAIL: leaked value present in (file):"; printf '%s\n' "$out"; fail=1 ;;
  *) echo "ERROR: hash scan failed (status $rc)"; fail=1 ;;
esac

echo "== self-test: temp git repo, same scan function"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
git -C "$T" init -q
mkdir -p "$T/src"
L="Synth""Val9x"   # synthetic literal assembled at runtime
q="'"; dq='"'; bt='`'
n=0
mk() { n=$((n+1)); printf '%s\n' "$2" > "$T/src/$1_$n.txt"; }

# positives (every shape; mixed case names; each must be reported)
mk pos "const ADMIN_PASSWORD = ${q}${L}${q};"
mk pos "let db_password = ${dq}${L}${dq}"
mk pos "var apiSecret = ${bt}${L}${bt}"
mk pos "export const SESSION_TOKEN=${q}${L}${q}"
mk pos "const x = process.env.ADMIN_PASSWORD || ${q}${L}${q};"
mk pos "const x = process.env.API_TOKEN ?? ${dq}${L}${dq};"
mk pos "const x = process.env[${q}DB_SECRET${q}] || ${q}${L}${q};"
mk pos "const x = process.env.GRAFANA_PASSWORD || ${bt}${L}${bt};"
mk pos "const x = process.env.stripe_api_key || ${q}${L}${q};"
mk pos "PGPASSWD=${q}${L}${q}"
mk pos 'echo "${ADMIN_PASSWORD:-'"${L}"'}"'
mk pos 'echo "${REDIS_PASSWORD:='"${L}"'}"'
mk pos 'echo "${JWT_SECRET-'"${L}"'}"'
mk pos "pw = os.environ.get(${q}ADMIN_PASSWORD${q}, ${q}${L}${q})"
mk pos "pw = os.getenv(${dq}DB_PASSWORD${dq}, ${dq}${L}${dq})"
mk pos "pw = os.environ.get(${q}X_TOKEN${q}) or ${q}${L}${q}"
mk pos "ADMIN_PASSWORD=${L}"
mk pos "export GRAFANA_ADMIN_PASSWORD=${L}"
mk pos "const g = ${q}NexaDuo""@2026-abc${q}"
npos=$n

# negatives (must not be reported)
mk neg "const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || '';"
mk neg "const ADMIN_PASSWORD = requireEnv('ADMIN_PASSWORD');"
mk neg "const t = process.env.API_TOKEN ?? 'abc';"
mk neg "const e = process.env.ADMIN_EMAIL || ${q}someone@example.org${q};"
mk neg "const p = process.env.X_PASSWORD || ${q}changeme-please${q};"
mk neg "const p = process.env.X_PASSWORD || ${q}<set me>${q};"
mk neg "const p = process.env.X_PASSWORD || ${q}\${OTHER_VAR}${q};"
mk neg "if (ADMIN_PASSWORD === ${q}${L}${q}) {}"
mk neg "if (token !== ${q}${L}${q}) {}"
mk neg 'echo "${ADMIN_PASSWORD:?must be set}"'
mk neg 'echo "${ADMIN_PASSWORD:-}"'
mk neg 'echo "${ADMIN_PASSWORD:-${OTHER}}"'
mk neg "pw = os.environ.get(${q}ADMIN_PASSWORD${q}, ${q}${q})"
mk neg "ADMIN_PASSWORD=\${FROM_ENV}"
mk neg "ADMIN_PASSWORD="
mk neg "ADMIN_PASSWORD=changeme"
mk neg "const timeout = process.env.TIMEOUT || ${q}30000000${q};"
mk neg "// the password is read from the environment"
git -C "$T" add src
sout=$(scan_tree "$T"); src_rc=$?
if [ "$src_rc" -ne 1 ]; then echo "FAIL: self-test scan returned $src_rc (expected 1)"; fail=1
else
  missed=0; falsepos=0
  for f in "$T"/src/pos_*.txt; do
    printf '%s\n' "$sout" | grep -q "^src/$(basename "$f"):1$" || { echo "FAIL: missed positive $(basename "$f")"; missed=1; }
  done
  for f in "$T"/src/neg_*.txt; do
    printf '%s\n' "$sout" | grep -q "^src/$(basename "$f"):1$" && { echo "FAIL: false positive $(basename "$f")"; falsepos=1; }
  done
  if [ "$missed" -eq 0 ] && [ "$falsepos" -eq 0 ]; then echo "PASS: $npos positives caught, negatives clean"; else fail=1; fi
fi

echo "== self-test: fail-closed outside a git work tree"
NG="$(mktemp -d)"
scan_tree "$NG" >/dev/null 2>&1; nrc=$?
rmdir "$NG"
if [ "$nrc" -eq 2 ]; then echo "PASS: non-git dir is an error, not a pass"; else echo "FAIL: non-git dir returned $nrc"; fail=1; fi

echo "== self-test: hash scan catches a synthetic leaked value"
H="$(printf %s "$L" | sha256sum | cut -d' ' -f1)"
printf '%s\n' "$H" > "$T/hashes.txt"
printf 'x = %s%s%s\n' "$q" "$L" "$q" > "$T/src/hashfix.txt"
git -C "$T" add src/hashfix.txt
hout=$(python3 -I "$HERE/leaked-hash-scan.py" "$T" "$T/hashes.txt"); hrc=$?
if [ "$hrc" -eq 1 ] && printf '%s' "$hout" | grep -q 'src/hashfix.txt'; then echo "PASS: hash scan positive"; else echo "FAIL: hash scan rc=$hrc"; fail=1; fi

exit "$fail"
