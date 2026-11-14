#!/usr/bin/env bash
# Regression test for issue #291 (backup-host.sh, restore-clone-secrets.sh,
# notify-operator.sh): remote resolved from ENV_FILE, bounded wait for Postgres,
# off-host sync/verify/scoped prune, clone-secrets archive, gpg encryption without
# plaintext leaks, forged-archive restore refusal, cron-minimal-PATH notification.
# Fake docker/rclone (filter-aware, local dirs) and a throwaway gpg homedir; synthetic
# data only: no live stack, no real secrets, no real remote. The `age` branch is NOT
# exercised (age is not installed on the host/CI). Playwright N/A (host cron/infra).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'gpgconf --homedir "$TMP/gnupg" --kill gpg-agent >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
REAL_GPG="$(command -v gpg || true)"
REAL_RCLONE="$(command -v rclone || true)"
if [[ "${REQUIRE_REAL_RCLONE:-0}" == 1 && -z "$REAL_RCLONE" ]]; then echo "FAIL: REQUIRE_REAL_RCLONE=1 but rclone is not installed"; exit 1; fi
ORIG_PATH="$PATH"
export HOME="$TMP/home"; mkdir -p "$HOME" "$TMP/bin"
export PATH="$TMP/bin:$PATH"
export NOTIFY_CMD="$TMP/bin/fake-notify"
unset BACKUP_RCLONE_REMOTE BACKUP_GPG_RECIPIENT BACKUP_AGE_RECIPIENT BACKUP_KEEP_DAYS BACKUP_CLONE_SECRET_PATHS
export BACKUP_MIN_BYTES=10 BACKUP_VOLUME_MIN_BYTES=10 BACKUP_ENV_MIN_BYTES=10
export BACKUP_VOLUME_SUFFIXES="chatwoot-storage" BACKUP_WAIT_INTERVAL=1

cat > "$TMP/bin/fake-notify" <<'STUB'
#!/bin/bash
echo "$*" >> "$FAKE_LOG_DIR/notify.log"
STUB
cat > "$TMP/bin/docker" <<'STUB'
#!/bin/bash
# Fake docker: only what backup-host.sh calls.
# FAKE_DOCKER_DOWN_CALLS=N|always => first N `ps` calls fail. FAKE_PG_NOTREADY_CALLS=N => first N pg_isready fail.
case "$1" in
  ps)
    n="$(cat "$FAKE_LOG_DIR/ps-count" 2>/dev/null || echo 0)"; echo $((n+1)) > "$FAKE_LOG_DIR/ps-count"
    if [[ "${FAKE_DOCKER_DOWN_CALLS:-0}" == always ]] || (( n < ${FAKE_DOCKER_DOWN_CALLS:-0} )); then
      echo "Cannot connect to the Docker daemon" >&2; exit 1; fi
    echo chat-services-postgres-1 ;;
  exec)
    if [[ "$*" == *pg_isready* ]]; then
      n="$(cat "$FAKE_LOG_DIR/pg-count" 2>/dev/null || echo 0)"; echo $((n+1)) > "$FAKE_LOG_DIR/pg-count"
      (( n >= ${FAKE_PG_NOTREADY_CALLS:-0} )) || { echo "no response" >&2; exit 2; }
    elif [[ "$*" == *psql* ]]; then printf 'chatwoot\nmiddleware\n'; [[ -z "${FAKE_DB_EXTRA:-}" ]] || echo "$FAKE_DB_EXTRA"; else seq 1 800; fi ;;
  volume) echo chat-services_chatwoot-storage ;;
  run) seq 1 800 | gzip ;;
  *) echo "unexpected docker $*" >&2; exit 99 ;;
esac
STUB
cat > "$TMP/bin/rclone" <<'STUB'
#!/bin/bash
# Fake rclone over local dirs with REAL filter semantics: ordered --filter rules
# (first match wins); legacy --include/--exclude are evaluated includes-first, like
# real rclone (so mixing them is a bug the suite would catch). --min-age Nd,
# top-level-only (--max-depth 1). FAKE_RCLONE_SKIP=<substr> drops matching files on copy.
echo "$*" >> "$FAKE_LOG_DIR/rclone.log"
cmd="$1"; shift
FIL=(); INC=(); EXC=(); pos=(); minage=""; fmt=""; sep=";"
while (( $# )); do
  case "$1" in
    --filter) FIL+=("$2"); shift 2 ;;
    --include) INC+=("$2"); shift 2 ;;
    --exclude) EXC+=("$2"); shift 2 ;;
    --min-age) minage="${2%d}"; shift 2 ;;
    --max-depth) shift 2 ;;
    --format) fmt="$2"; shift 2 ;;
    --separator) sep="$2"; shift 2 ;;
    *) pos+=("$1"); shift ;;
  esac
done
ok() { local name="$1" r pat
  if (( ${#FIL[@]} )); then
    for r in "${FIL[@]}"; do pat="${r:2}"; pat="${pat#/}"
      if [[ "$name" == $pat ]]; then [[ "${r:0:1}" == + ]] && return 0 || return 1; fi; done
    return 0
  fi
  for pat in "${INC[@]}"; do pat="${pat#/}"; [[ "$name" == $pat ]] && return 0; done
  (( ${#INC[@]} )) && return 1
  for pat in "${EXC[@]}"; do pat="${pat#/}"; [[ "$name" == $pat ]] && return 1; done
  return 0; }
case "$cmd" in
  copy) src="${pos[0]}"; dst="${pos[1]}"; mkdir -p "$dst"
    for f in "$src"/*; do [[ -f "$f" ]] || continue; n="$(basename "$f")"
      [[ -n "${FAKE_RCLONE_SKIP:-}" && "$n" == *"$FAKE_RCLONE_SKIP"* ]] && continue
      ok "$n" || continue
      cp -n --preserve=timestamps "$f" "$dst/"; done ;;
  lsf) [[ -d "${pos[0]}" ]] || { echo "directory not found" >&2; exit 3; }
    for f in "${pos[0]}"/*; do [[ -f "$f" ]] || continue; n="$(basename "$f")"; ok "$n" || continue
      if [[ "$fmt" == ps ]]; then echo "${n}${sep}$(stat -c%s "$f")"; else echo "$n"; fi; done; true ;;
  delete) for f in "${pos[0]}"/*; do [[ -f "$f" ]] || continue; n="$(basename "$f")"; ok "$n" || continue
      if [[ -z "$minage" ]] || (( $(date +%s) - $(stat -c%Y "$f") > minage*86400 )); then
        echo "$n" >> "$FAKE_LOG_DIR/deleted.log"; rm -f "$f"; fi; done ;;
  *) echo "unexpected rclone $cmd" >&2; exit 99 ;;
esac
STUB
cat > "$TMP/bin/fake-sleep" <<'STUB'
#!/bin/bash
# Virtual clock: advances instead of sleeping (deterministic wait-loop tests).
echo $(( $(cat "$FAKE_LOG_DIR/clock") + $1 )) > "$FAKE_LOG_DIR/clock"
STUB
cat > "$TMP/bin/fake-clock" <<'STUB'
#!/bin/bash
cat "$FAKE_LOG_DIR/clock"
STUB
if [[ -n "$REAL_GPG" ]]; then
cat > "$TMP/bin/gpg" <<STUB
#!/bin/bash
# Wrapper: FAKE_GPG_FAIL=1 makes --encrypt fail (key listing still works); else real gpg.
if [[ -n "\${FAKE_GPG_FAIL_AFTER:-}" && "\$*" == *--encrypt* ]]; then
  n="\$(cat "\$FAKE_LOG_DIR/gpg-enc-count" 2>/dev/null || echo 0)"; echo \$((n+1)) > "\$FAKE_LOG_DIR/gpg-enc-count"
  if (( n >= FAKE_GPG_FAIL_AFTER )); then cat >/dev/null; echo "gpg: encryption failed (fake)" >&2; exit 2; fi
fi
exec $REAL_GPG "\$@"
STUB
fi
chmod +x "$TMP/bin/"*

fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "PASS: $*"; }
has() { compgen -G "$1" >/dev/null; }

# fresh scenario dir: fake clone with allowlist (synthetic content), dumps dir, existing remote dir
scenario() {
  S="$TMP/$1"; rm -rf "$S"; mkdir -p "$S/clone/deploy" "$S/clone/.claude" "$S/clone/infrastructure/terraform/envs/production" "$S/dumps" "$S/remote" "$S/log"
  # inline comment, quotes and CRLF on purpose (env parser)
  printf 'SYNTH_A=1\r\nSYNTH_B=two\r\nBACKUP_RCLONE_REMOTE="%s"   # onedrive folder\r\n' "$S/remote" > "$S/clone/.env"
  echo 'SYNTH_DEV=1' > "$S/clone/deploy/.env"
  echo 'synthetic = "tfvars"' > "$S/clone/infrastructure/terraform/envs/production/terraform.tfvars"
  echo '{"synthetic":true}' > "$S/clone/.claude/settings.local.json"
  export FAKE_LOG_DIR="$S/log" BACKUP_DIR="$S/dumps" BACKUP_REPO_ROOT="$S/clone" ENV_FILE="$S/clone/.env"
  echo 0 > "$S/log/clock"
  export BACKUP_TEST_MODE=1 BACKUP_WAIT_SECONDS=5 NOTIFY_STATE_DIR="$S/notify-state" BACKUP_SLEEP_CMD="$TMP/bin/fake-sleep" BACKUP_CLOCK_CMD="$TMP/bin/fake-clock"
  unset FAKE_DOCKER_DOWN_CALLS FAKE_PG_NOTREADY_CALLS FAKE_RCLONE_SKIP FAKE_GPG_FAIL_AFTER FAKE_DB_EXTRA BACKUP_CLONE_REQUIRED_PATHS BACKUP_RCLONE_REMOTE BACKUP_GPG_RECIPIENT BACKUP_KEEP_DAYS BACKUP_CLONE_SECRET_PATHS || true
}
run_backup() { bash "$ROOT/scripts/backup-host.sh" > "$S/out" 2>&1; }

# 1. happy path; remote only in ENV_FILE (quoted + inline comment + CRLF); scoped prune
scenario plain
for f in other.tar.gz legacy.sql.gz notes-2000-01-01-0300.txt thesis-2020-01-01-0000.tar.gz holiday-abcd-ef-gh-ijkl.tar.gz; do echo x > "$S/remote/$f"; touch -d '40 days ago' "$S/remote/$f"; done
mkdir -p "$S/remote/sub"; echo x > "$S/remote/sub/chatwoot-2000-01-01-0300.sql.gz"; touch -d '40 days ago' "$S/remote/sub/chatwoot-2000-01-01-0300.sql.gz"
echo old > "$S/remote/chatwoot-2000-01-01-0300.sql.gz"; touch -d '40 days ago' "$S/remote/chatwoot-2000-01-01-0300.sql.gz"
run_backup || { cat "$S/out"; fail "plain backup should succeed"; }
grep -q 'BACKUP_RCLONE_REMOTE resolvido de ENV_FILE' "$S/out" || fail "remote not resolved from ENV_FILE"
grep -q 'TEXTO PLANO' "$S/out" || fail "missing plaintext warning"
cs="$(ls "$S"/dumps/clone-secrets-*.tar.gz)"
[[ "$(stat -c%a "$cs")" == 600 ]] || fail "clone-secrets perms not 0600"
[[ "$(stat -c%a "$S/dumps")" == 700 ]] || fail "dumps dir not 0700"
[[ "$(stat -c%a "$(ls "$S"/dumps/chatwoot-2*.sql.gz)")" == 600 ]] || fail "dump not 0600 (umask)"
has "$S/remote/clone-secrets-*.tar.gz" || fail "clone-secrets not off-host"
grep -q 'offhost=verified' "$S/dumps/.last-success" || fail "offhost not verified"
grep -q 'delete .*--min-age 14d.*--max-depth 1' "$S/log/rclone.log" || fail "prune not bounded"
grep -q -- "--filter + /chatwoot-\[0-9\]" "$S/log/rclone.log" || fail "filters not anchored/prefixed"
grep -q -- '--include\|--exclude' "$S/log/rclone.log" && fail "include/exclude must not be used (real rclone ignores their order)"
for f in other.tar.gz legacy.sql.gz notes-2000-01-01-0300.txt thesis-2020-01-01-0000.tar.gz holiday-abcd-ef-gh-ijkl.tar.gz sub/chatwoot-2000-01-01-0300.sql.gz; do
  [[ -f "$S/remote/$f" ]] || fail "prune deleted unrelated remote file $f"; done
[[ ! -f "$S/remote/chatwoot-2000-01-01-0300.sql.gz" ]] || fail "old generated-name file not pruned"
[[ ! -e "$S/dumps/.backup-last-fail" ]] || fail "fail marker should be absent on success"
ok "remote from ENV_FILE (quotes/comment/CRLF), perms 0600/0700, scoped prune keeps unrelated files"

mkdir "$S/restored"
bash "$ROOT/scripts/restore-clone-secrets.sh" "$cs" --target "$S/restored" --dry-run > "$S/o" 2>&1 || fail "dry-run"
[[ -z "$(ls -A "$S/restored")" ]] || fail "dry-run wrote files"
bash "$ROOT/scripts/restore-clone-secrets.sh" "$S/remote/$(basename "$cs")" --target "$S/restored" > "$S/o" 2>&1 || fail "restore"
for f in .env deploy/.env infrastructure/terraform/envs/production/terraform.tfvars .claude/settings.local.json; do
  diff -q "$S/clone/$f" "$S/restored/$f" >/dev/null || fail "restored $f differs"
done
if bash "$ROOT/scripts/restore-clone-secrets.sh" "$cs" --target "$S/restored" > "$S/o" 2>&1; then fail "restore overwrote without --force"; fi
bash "$ROOT/scripts/restore-clone-secrets.sh" "$cs" --target "$S/restored" --force > "$S/o" 2>&1 || fail "restore --force"
ok "restore round trip, dry-run, refuses overwrite without --force"

# 2. missed day: older local dump not yet remote is synced (no --max-age)
scenario missed
echo old-dump-content > "$S/dumps/chatwoot-2000-01-01-0300.sql.gz"; touch -d '3 days ago' "$S/dumps/chatwoot-2000-01-01-0300.sql.gz"
run_backup || { cat "$S/out"; fail "missed-day backup"; }
[[ -f "$S/remote/chatwoot-2000-01-01-0300.sql.gz" ]] || fail "older unsynced dump not copied"
grep -q -- '--max-age' "$S/log/rclone.log" && fail "--max-age still used"
ok "missed day syncs everything not yet remote"

# 3. remote verification failure fails the run, no prune
scenario verify
export FAKE_RCLONE_SKIP="middleware-"
if run_backup; then fail "should fail when remote lacks a new file"; fi
grep -q 'off-host sem' "$S/out" || fail "no off-host verification error"
grep -q 'delete' "$S/log/rclone.log" && fail "pruned remote despite failed verification"
grep -q 'offhost=verified' "$S/dumps/.last-success" 2>/dev/null && fail "marked verified"
ok "off-host verification failure fails run, no prune"

# 3b. remote dir missing => fail, never silently created
scenario noremote
rmdir "$S/remote"
if run_backup; then fail "should fail when remote dir is missing"; fi
grep -q 'inexistente' "$S/out" || fail "no missing-remote message"
[[ ! -e "$S/remote" ]] || fail "remote dir was created silently"
has "$S/dumps/chatwoot-*.sql.gz" && has "$S/dumps/middleware-*.sql.gz" && has "$S/dumps/chat-services_chatwoot-storage-*.tar.gz" || fail "LOCAL dumps/volumes must still be taken with an unusable remote"
has "$S/dumps/env-*.tar.gz" && has "$S/dumps/clone-secrets-*.tar.gz" || fail "local secrets archives must still be taken"
grep -q 'local=ok' "$S/dumps/.last-success" && grep -q 'offhost=failed reason=' "$S/dumps/.last-success" || fail ".last-success must record local=ok offhost=failed reason"
[[ -s "$S/dumps/.backup-last-fail" ]] || fail "no fail marker"
grep -q 'Backup FALHOU' "$S/log/notify.log" || fail "no notification"
ok "missing remote: local backup complete, off-host fails loudly (marker, notify, .last-success reason), dir not created"

# 3c. KEEP_DAYS=0 refused; empty env var forces local-only
scenario keep0
export BACKUP_KEEP_DAYS=0
if run_backup; then fail "KEEP_DAYS=0 must fail"; fi
grep -q 'BACKUP_KEEP_DAYS inválido' "$S/out" || fail "no keep-days message"
scenario localonly
export BACKUP_RCLONE_REMOTE=
run_backup || { cat "$S/out"; fail "local-only run"; }
[[ ! -e "$S/log/rclone.log" ]] || fail "rclone ran despite explicit empty remote"
ok "KEEP_DAYS<1 refused; explicit empty remote forces local-only"

# 3d. numeric settings: base-10 and bounded; flock prevents overlap
scenario waitzero
export BACKUP_WAIT_SECONDS=0009 FAKE_DOCKER_DOWN_CALLS=always
if run_backup; then fail "must fail when docker down"; fi
grep -q 'após 9s' "$S/out" || fail "0009 not parsed as decimal 9"
[[ "$(cat "$S/log/clock")" -le 10 ]] || fail "wait not bounded by virtual clock"
scenario waitbad
export BACKUP_WAIT_SECONDS=abc
if run_backup; then fail "non-numeric wait accepted"; fi
grep -q 'BACKUP_WAIT_SECONDS inválido' "$S/out" || fail "no invalid-wait message"
export BACKUP_WAIT_SECONDS=999999999
if run_backup; then fail "unbounded wait accepted"; fi
scenario lock
exec 7>"$S/dumps/.backup.lock"; flock -n 7
run_backup || fail "contended run should exit 0 (skipped)"
grep -q 'mantém o lock' "$S/out" || fail "no skip message"
grep -q '^count=1 ' "$S/dumps/.backup-skipped" || fail "skip not recorded in .backup-skipped"
has "$S/dumps/chatwoot-*" && fail "skipped run took dumps"
[[ ! -e "$S/dumps/.backup-last-fail" ]] || fail "skipped run must not write fail marker"
exec 7>&-
# a flock failure that is NOT contention must be a real error
mkdir -p "$TMP/bin-flock"; printf '#!/bin/bash\nexit 66\n' > "$TMP/bin-flock/flock"; chmod +x "$TMP/bin-flock/flock"
if PATH="$TMP/bin-flock:$PATH" run_backup; then fail "non-contention flock failure treated as skip"; fi
grep -q 'não é contenção' "$S/out" || fail "no flock error message"
run_backup || { cat "$S/out"; fail "run after lock release"; }
[[ ! -e "$S/dumps/.backup-skipped" ]] || fail ".backup-skipped not cleared on success"
ok "numeric settings decimal+bounded, deterministic wait, flock skips overlap without stuck lock"

# 4. required .env missing in clone fails
scenario noenv
rm "$S/clone/.env"; ENV_FILE="$S/other.env"; echo 'X=1' > "$ENV_FILE"; export ENV_FILE
if run_backup; then fail "should fail without required .env"; fi
grep -q "obrigatório '.env' ausente" "$S/out" || fail "missing .env not reported"
ok "missing required .env fails"

# 4b. allowlist hardening: traversal, symlink out of repo; symlink inside repo archived as content
scenario badpath
export BACKUP_CLONE_SECRET_PATHS=".env ../outside"
if run_backup; then fail "'..' entry must fail"; fi
grep -q 'entrada inválida' "$S/out" || fail "no invalid entry message"
scenario symout
echo 'OUTSIDE_SECRET=1' > "$S/outside.txt"; ln -sf "$S/outside.txt" "$S/clone/skills-lock.json"
export BACKUP_CLONE_SECRET_PATHS=".env skills-lock.json"
if run_backup; then fail "symlink escaping repo must fail"; fi
grep -q 'fora do repositório' "$S/out" || fail "no outside-repo message"
scenario symin
echo 'INSIDE=1' > "$S/clone/real.json"; ln -sf real.json "$S/clone/skills-lock.json"
export BACKUP_CLONE_SECRET_PATHS=".env skills-lock.json"
run_backup || { cat "$S/out"; fail "inside symlink"; }
mkdir "$S/restored"; bash "$ROOT/scripts/restore-clone-secrets.sh" "$(ls "$S"/dumps/clone-secrets-*.tar.gz)" --target "$S/restored" >/dev/null 2>&1 || fail "restore symin"
[[ -f "$S/restored/skills-lock.json" && ! -L "$S/restored/skills-lock.json" ]] || fail "symlink not archived as content"
ok "allowlist rejects .., outside-repo symlinks; inside symlink archived as content"

# 5. Docker down: bounded wait, marker, notification
scenario down
export FAKE_DOCKER_DOWN_CALLS=always BACKUP_WAIT_SECONDS=3
if run_backup; then fail "should fail when docker stays down"; fi
grep -q 'nova tentativa' "$S/out" || fail "no retry"
[[ -s "$S/dumps/.backup-last-fail" ]] || fail "no fail marker"
grep -q 'Backup FALHOU' "$S/log/notify.log" || fail "no notification"
ok "docker down: waits, fails, marker + notification"

# 6. Docker recovers; Postgres listed but not accepting connections yet, then ready
scenario recover
export FAKE_DOCKER_DOWN_CALLS=2
run_backup || { cat "$S/out"; fail "should succeed once docker returns"; }
[[ "$(cat "$S/log/ps-count")" -ge 3 ]] || fail "did not retry"
scenario pgready
export FAKE_PG_NOTREADY_CALLS=2
run_backup || { cat "$S/out"; fail "should wait for pg_isready"; }
[[ "$(cat "$S/log/pg-count")" -ge 3 ]] || fail "did not retry pg_isready"
scenario pgnever
export FAKE_PG_NOTREADY_CALLS=999 BACKUP_WAIT_SECONDS=3
if run_backup; then fail "must fail when Postgres never becomes ready"; fi
ok "waits for Postgres to accept connections, bounded"

# 7. gpg public-key encryption
if [[ -n "$REAL_GPG" ]]; then
  export GNUPGHOME="$TMP/gnupg"; mkdir -m 700 "$GNUPGHOME"
  gpg --batch --quiet --passphrase '' --quick-generate-key backup-test@example.invalid default default never 2>/dev/null
  FPR="$("$REAL_GPG" --list-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')"
  scenario gpg
  export BACKUP_GPG_RECIPIENT="$FPR"
  run_backup || { cat "$S/out"; fail "gpg backup"; }
  has "$S/dumps/clone-secrets-*.tar.gz.gpg" || fail "no .gpg archive"
  has "$S/dumps/env-*.tar.gz.gpg" || fail "env archive not encrypted"
  has "$S/dumps/clone-secrets-*.tar.gz" && fail "plaintext clone archive left behind"
  has "$S/dumps/env-*.tar.gz" && fail "plaintext env archive left behind"
  has "$S/remote/env-*.tar.gz" && fail "plaintext env on remote"
  has "$S/remote/clone-secrets-*.tar.gz" && fail "plaintext clone-secrets on remote"
  grep -q 'TEXTO PLANO' "$S/out" && fail "plaintext warning despite recipient"
  grep -q 'encrypted=gpg' "$S/dumps/.last-success" || fail "encrypted flag missing"
  grep -q 'SYNTH_A' "$S"/dumps/clone-secrets-*.tar.gz.gpg && fail "secret visible in ciphertext"
  mkdir "$S/restored"
  bash "$ROOT/scripts/restore-clone-secrets.sh" "$S"/remote/clone-secrets-*.tar.gz.gpg --target "$S/restored" > "$S/o" 2>&1 || { cat "$S/o"; fail "gpg restore"; }
  diff -q "$S/clone/.env" "$S/restored/.env" >/dev/null || fail "gpg restored .env differs"
  ok "gpg encryption (no plaintext local/remote), restore"

  # SEC-1/REV-2/REV-17: encryption failing MID-RUN (probe passes, real encrypt fails): the LOCAL
  # backup completes (plaintext secrets stay local only), nothing off-host, run fails loudly, remote
  # plaintext is NOT deleted without a verified replacement, and the NEXT good run quarantines
  # leftover plaintext and never uploads it.
  scenario gpgfail
  export BACKUP_GPG_RECIPIENT="$FPR" FAKE_GPG_FAIL_AFTER=1
  echo legacy-plain > "$S/remote/env-1999-01-01-0000.tar.gz"
  if run_backup; then fail "failed encryption must fail the run"; fi
  has "$S/dumps/chatwoot-*.sql.gz" || fail "dumps must stay local after failed encryption"
  has "$S/dumps/.stage.*/*" && fail "staging not cleaned"
  [[ -s "$S/dumps/.backup-last-fail" ]] || fail "no fail marker after failed encryption"
  grep -q 'offhost=failed' "$S/dumps/.last-success" && grep -q 'encrypted=broken' "$S/dumps/.last-success" || fail ".last-success must record local ok / off-host failed"
  [[ "$(stat -c%a "$(ls "$S"/dumps/env-*.tar.gz)")" == 600 ]] || fail "local plaintext fallback must be 0600"
  has "$S/remote/chatwoot-*" && fail "nothing from a failed run may reach the remote"
  has "$S/remote/env-2*" && fail "plaintext secrets reached the remote"
  [[ -f "$S/remote/env-1999-01-01-0000.tar.gz" ]] || fail "remote plaintext deleted without verified encrypted replacement"
  unset FAKE_GPG_FAIL_AFTER
  echo legacy-plain > "$S/dumps/env-2000-01-01-0000.tar.gz"   # more legacy local plaintext
  run_backup || { cat "$S/out"; fail "run after failed encryption"; }
  has "$S/dumps/env-*[0-9].tar.gz" && fail "plaintext env left at top level of dumps after good run"
  [[ -f "$S/dumps/quarantine-plaintext/env-2000-01-01-0000.tar.gz" ]] || fail "plaintext not quarantined"
  has "$S/remote/env-2000-*" && fail "pre-existing local plaintext was uploaded"
  grep -q 'TEXTO PLANO pré-existente' "$S/out" || fail "no quarantine warning"
  grep -q 'já existem no remote' "$S/out" || fail "pre-existing remote plaintext not listed"
  [[ ! -f "$S/remote/env-1999-01-01-0000.tar.gz" ]] || fail "remote plaintext not removed after verified encrypted replacement"
  has "$S/remote/env-*.tar.gz.gpg" || fail "encrypted replacement missing on remote"
  ok "mid-run encryption failure: local backup kept (plaintext local-only 0600), no upload, loud fail; next run quarantines"

  # REV-17: bad recipient formats/unknown keys no longer block the LOCAL backup
  scenario gpgbad
  export BACKUP_GPG_RECIPIENT="short-id"
  if run_backup; then fail "malformed recipient must fail"; fi
  grep -q 'fingerprint completo' "$S/out" || fail "no recipient format message"
  has "$S/dumps/chatwoot-*.sql.gz" || fail "bad recipient must NOT block local dumps"
  has "$S/remote/*" && fail "bad recipient: something was uploaded"
  [[ -s "$S/dumps/.backup-last-fail" ]] || fail "no fail marker for bad recipient"
  export BACKUP_GPG_RECIPIENT="0000000000000000000000000000000000000000"
  if run_backup; then fail "unknown key must fail"; fi
  has "$S/remote/*" && fail "unknown key: something was uploaded"
  ok "bad/unknown recipient: local backup kept, nothing uploaded, non-zero + marker"

  # REV-17: imported-but-untrusted public key (list-keys works, encrypt fails) is caught at validation
  scenario untrusted
  G2="$TMP/gnupg2"; mkdir -m 700 "$G2"
  "$REAL_GPG" --export "$FPR" | GNUPGHOME="$G2" "$REAL_GPG" --batch --quiet --import 2>/dev/null
  GNUPGHOME="$G2" "$REAL_GPG" --batch --list-keys "$FPR" >/dev/null 2>&1 || fail "setup: key not imported"
  export BACKUP_GPG_RECIPIENT="$FPR"
  if GNUPGHOME="$G2" run_backup; then fail "untrusted key must fail"; fi
  grep -q 'não consegue criptografar' "$S/out" || { cat "$S/out"; fail "untrusted key not caught by real test encryption"; }
  has "$S/dumps/chatwoot-*.sql.gz" || fail "untrusted key must not block local dumps"
  has "$S/remote/*" && fail "untrusted key: something was uploaded"
  gpgconf --homedir "$G2" --kill gpg-agent >/dev/null 2>&1 || true
  ok "untrusted imported key fails at validation via real test encryption; local backup kept"

  # purge guard: if clone-secrets could not be archived, remote plaintext must NOT be deleted
  scenario purgeguard
  export BACKUP_GPG_RECIPIENT="$FPR" BACKUP_CLONE_SECRET_PATHS=".env nonexistent.json" BACKUP_CLONE_REQUIRED_PATHS=".env nonexistent.json"
  echo legacy > "$S/remote/env-1999-01-01-0000.tar.gz"; echo legacy > "$S/remote/clone-secrets-1999-01-01-0000.tar.gz"
  if run_backup; then fail "missing required clone path must fail"; fi
  [[ -f "$S/remote/env-1999-01-01-0000.tar.gz" && -f "$S/remote/clone-secrets-1999-01-01-0000.tar.gz" ]] || fail "purge ran without both encrypted replacements"
  ok "remote plaintext purge requires both encrypted archives"

  # SEC-13: a DB named '*' is never dumped nor turned into a filter; foreign files survive
  scenario dbname
  export FAKE_DB_EXTRA='*'
  echo x > "$S/remote/thesis-2020-01-01-0000.sql.gz"; touch -d '40 days ago' "$S/remote/thesis-2020-01-01-0000.sql.gz"
  if run_backup; then fail "invalid DB name must fail the run"; fi
  grep -q 'nome de DB fora de' "$S/out" || fail "no invalid DB name message"
  has "$S/dumps/\*-*" && fail "dump file named from invalid DB"
  grep -q 'local=partial' "$S/dumps/.last-success" || fail "local=partial not recorded"
  [[ -f "$S/remote/thesis-2020-01-01-0000.sql.gz" ]] || fail "foreign remote file pruned via glob DB name"
  ok "invalid DB names skipped (loud, local=partial); no glob injection into prune"

  # REV-16 against the REAL rclone binary: the raced-plaintext upload must be blocked by the
  # filter order ITSELF. No remote plaintext is seeded, so the purge never runs and cannot hide a leak.
  if [[ -n "$REAL_RCLONE" ]]; then
    mkdir -p "$TMP/bin-real"
    for t in docker fake-notify fake-sleep fake-clock gpg; do ln -sf "$TMP/bin/$t" "$TMP/bin-real/$t"; done
    cat > "$TMP/bin-real/rclone" <<STUB
#!/bin/bash
if [[ "\$1" == copy ]]; then echo plaintext-race > "\$2/env-2099-01-01-0000.tar.gz"; echo plaintext-race > "\$2/clone-secrets-2099-01-01-0000.tar.gz"; fi
exec $REAL_RCLONE "\$@"
STUB
    chmod +x "$TMP/bin-real/rclone"
    scenario realrace
    export BACKUP_GPG_RECIPIENT="$FPR"
    PATH="$TMP/bin-real:$ORIG_PATH" run_backup || { cat "$S/out"; fail "real rclone race run"; }
    has "$S/remote/env-2099-*" && fail "REAL rclone uploaded raced plaintext env (filter order broken)"
    has "$S/remote/clone-secrets-2099-*" && fail "REAL rclone uploaded raced plaintext clone-secrets (filter order broken)"
    has "$S/remote/env-*.tar.gz.gpg" && has "$S/remote/chatwoot-*.sql.gz" || fail "encrypted/dump files missing on remote"
    grep -q 'Using --filter is recommended' "$S/out" && fail "mixed include/exclude warning from real rclone"
    ok "REAL rclone: filter order itself blocks raced plaintext (no purge involved)"
    # purge + prune scope with the real binary (separate scenario, no race)
    ln -sf "$REAL_RCLONE" "$TMP/bin-real/rclone"
    scenario realpurge
    export BACKUP_GPG_RECIPIENT="$FPR"
    for f in env-1999-01-01-0000.tar.gz clone-secrets-1999-01-01-0000.tar.gz thesis-2020-01-01-0000.tar.gz other.tar.gz chatwoot-2000-01-01-0300.sql.gz dropped_db-2000-01-01-0300.sql.gz env-manual.tar.gz; do
      echo old > "$S/remote/$f"; touch -d '40 days ago' "$S/remote/$f"; done
    PATH="$TMP/bin-real:$ORIG_PATH" run_backup || { cat "$S/out"; fail "real rclone purge run"; }
    has "$S/remote/env-1999-*" && fail "old remote plaintext env not removed"
    has "$S/remote/clone-secrets-1999-*" && fail "old remote plaintext clone-secrets not removed"
    [[ -f "$S/remote/thesis-2020-01-01-0000.tar.gz" && -f "$S/remote/other.tar.gz" && -f "$S/remote/dropped_db-2000-01-01-0300.sql.gz" && -f "$S/remote/env-manual.tar.gz" ]] || fail "REAL prune/purge deleted files outside its scope"
    [[ ! -f "$S/remote/chatwoot-2000-01-01-0300.sql.gz" ]] || fail "REAL prune missed old generated dump"
    grep -q 'env-manual.tar.gz' "$S/out" && grep -q 'dropped_db-2000' "$S/out" || fail "odd-named plaintext / dropped-DB archives not warned about"
    ok "REAL rclone: prune/purge scoped; odd-named plaintext and dropped-DB archives warned, not deleted"
  elif [[ "${REQUIRE_REAL_RCLONE:-0}" == 1 ]]; then
    fail "real rclone required"
  else
    echo "SKIP: real rclone not installed"
  fi

  # verify-backup-decrypt.sh: proves the archive is recoverable with the private key
  scenario verify_decrypt
  export BACKUP_GPG_RECIPIENT="$FPR"
  run_backup || { cat "$S/out"; fail "run for verify-decrypt"; }
  bash "$ROOT/scripts/verify-backup-decrypt.sh" "$(ls "$S"/remote/clone-secrets-*.gpg)" > "$S/o" 2>&1 || { cat "$S/o"; fail "verify-backup-decrypt"; }
  grep -q '^OK:' "$S/o" || fail "verify-backup-decrypt output"
  ok "verify-backup-decrypt.sh proves recoverability"
else
  [[ "${REQUIRE_REAL_RCLONE:-0}" != 1 ]] || { echo "FAIL: gpg required"; exit 1; }
  echo "SKIP: gpg not installed"
fi

# 5b. test hooks are inert without BACKUP_TEST_MODE=1; default clock/sleep path works
scenario inert
unset BACKUP_TEST_MODE
export BACKUP_CLOCK_CMD="touch $S/clock-hook-ran" BACKUP_SLEEP_CMD="touch $S/sleep-hook-ran" FAKE_DOCKER_DOWN_CALLS=1 BACKUP_WAIT_SECONDS=30 BACKUP_WAIT_INTERVAL=1
run_backup || { cat "$S/out"; fail "default clock/sleep path"; }
[[ ! -e "$S/clock-hook-ran" && ! -e "$S/sleep-hook-ran" ]] || fail "env hooks executed without BACKUP_TEST_MODE"
[[ "$(cat "$S/log/ps-count")" -ge 2 ]] || fail "wait loop did not retry with real sleep"
ok "clock/sleep hooks inert without BACKUP_TEST_MODE; default path retries and succeeds"
export BACKUP_TEST_MODE=1

# 8. restore refuses forged archives, writes nothing
FG="$TMP/forge"; mkdir -p "$FG/src/.git/hooks" "$FG/t1" "$FG/t2" "$FG/t3"
printf '#!/bin/sh\necho pwned\n' > "$FG/src/.git/hooks/post-checkout"; chmod 755 "$FG/src/.git/hooks/post-checkout"
tar czf "$FG/hook.tar.gz" -C "$FG/src" .git/hooks/post-checkout
ln -s /etc/passwd "$FG/src/.env"; tar czf "$FG/link.tar.gz" -C "$FG/src" .env
echo x > "$FG/src/unlisted.txt"; tar czf "$FG/unlisted.tar.gz" -C "$FG/src" unlisted.txt
if bash "$ROOT/scripts/restore-clone-secrets.sh" "$FG/hook.tar.gz" --target "$FG/t1" > "$FG/o" 2>&1; then fail ".git hook archive accepted"; fi
if bash "$ROOT/scripts/restore-clone-secrets.sh" "$FG/hook.tar.gz" --target "$FG/t1" --allow .git/hooks/post-checkout > "$FG/o" 2>&1; then fail "--allow must not permit .git"; fi
if bash "$ROOT/scripts/restore-clone-secrets.sh" "$FG/link.tar.gz" --target "$FG/t2" > "$FG/o" 2>&1; then fail "symlink archive accepted"; fi
if bash "$ROOT/scripts/restore-clone-secrets.sh" "$FG/unlisted.tar.gz" --target "$FG/t3" > "$FG/o" 2>&1; then fail "unlisted path accepted"; fi
[[ -z "$(ls -A "$FG/t1")$(ls -A "$FG/t2")$(ls -A "$FG/t3")" && ! -e "$FG/t1/.git" ]] || fail "forged archive wrote files"
bash "$ROOT/scripts/restore-clone-secrets.sh" "$FG/unlisted.tar.gz" --target "$FG/t3" --allow unlisted.txt >/dev/null 2>&1 || fail "explicit --allow should work"
# TOCTOU: swapping the SOURCE after validation must not matter (we extract from a private copy);
# tampering with the private copy is detected by the sha256 check.
RS="$TMP/restore-toctou"; mkdir -p "$RS/t" "$RS/t2" "$RS/ok"
echo 'SYNTH=1' > "$RS/ok/skills-lock.json"; tar czf "$RS/benign.tar.gz" -C "$RS/ok" skills-lock.json
cp "$RS/benign.tar.gz" "$RS/src.tar.gz"
RESTORE_TEST_HOOK="cp '$FG/hook.tar.gz' '$RS/src.tar.gz'" bash "$ROOT/scripts/restore-clone-secrets.sh" "$RS/src.tar.gz" --target "$RS/t" > "$RS/o" 2>&1 || { cat "$RS/o"; fail "restore with swapped source"; }
[[ -f "$RS/t/skills-lock.json" && ! -e "$RS/t/.git" ]] || fail "source swap influenced extraction"
if RESTORE_TEST_HOOK='cp '"'$FG/hook.tar.gz'"' "$1"' bash "$ROOT/scripts/restore-clone-secrets.sh" "$RS/benign.tar.gz" --target "$RS/t2" > "$RS/o" 2>&1; then fail "tampered private copy not detected"; fi
[[ -z "$(ls -A "$RS/t2")" ]] || fail "tampered copy wrote files"
mkdir "$RS/t5"
env -u BACKUP_TEST_MODE RESTORE_TEST_HOOK="touch $RS/hooked" bash "$ROOT/scripts/restore-clone-secrets.sh" "$RS/benign.tar.gz" --target "$RS/t5" > "$RS/o" 2>&1 || fail "restore with ignored hook"
[[ ! -e "$RS/hooked" ]] || fail "RESTORE_TEST_HOOK executed without BACKUP_TEST_MODE"
# mode bits ignored (0777 -> 0600); duplicate members refused with nothing written; warning printed
chmod 777 "$RS/ok/skills-lock.json"; tar czf "$RS/mode.tar.gz" -C "$RS/ok" skills-lock.json; mkdir "$RS/t3"
bash "$ROOT/scripts/restore-clone-secrets.sh" "$RS/mode.tar.gz" --target "$RS/t3" > "$RS/o" 2>&1 || fail "mode restore"
[[ "$(stat -c%a "$RS/t3/skills-lock.json")" == 600 ]] || fail "archive mode bits not ignored"
grep -q 'NÃO é autenticado' "$RS/o" || fail "no unauthenticated-content warning"
tar cf "$RS/dup.tar" -C "$RS/ok" skills-lock.json; tar rf "$RS/dup.tar" -C "$RS/ok" skills-lock.json; gzip -f "$RS/dup.tar"; mkdir "$RS/t4"
if bash "$ROOT/scripts/restore-clone-secrets.sh" "$RS/dup.tar.gz" --target "$RS/t4" > "$RS/o" 2>&1; then fail "duplicate members accepted"; fi
[[ -z "$(ls -A "$RS/t4")" ]] || fail "duplicate-member archive wrote files"
# default allowlists: exact set comparison between backup-host.sh and restore script (+ mutation check)
al_backup() { grep -o 'BACKUP_CLONE_SECRET_PATHS:=[^}]*' "$ROOT/scripts/backup-host.sh" | head -n1 | sed 's/^[^=]*=//' | tr ' ' '\n' | sort; }
al_restore() { sed -n 's/^DEFAULT_ALLOW=(\(.*\))$/\1/p' "${1:-$ROOT/scripts/restore-clone-secrets.sh}" | tr ' ' '\n' | sort; }
[[ -n "$(al_backup)" ]] && diff <(al_backup) <(al_restore) >/dev/null || fail "restore DEFAULT_ALLOW differs from backup default allowlist"
sed 's/^DEFAULT_ALLOW=(\.env /DEFAULT_ALLOW=(/' "$ROOT/scripts/restore-clone-secrets.sh" > "$TMP/restore-mutant.sh"
diff <(al_backup) <(al_restore "$TMP/restore-mutant.sh") >/dev/null && fail "allowlist comparison missed a removed entry (mutation)"
ok "restore: private-copy TOCTOU, mode bits, duplicates, warning; allowlists identical (mutation detected)"

# 9. notification works from cron's minimal PATH; undelivered is never silent
NS="$TMP/notify-cron"; mkdir -p "$NS"
cat > "$NS/fakeps" <<'STUB'
#!/bin/bash
echo "$NOTIFY_TITLE|$NOTIFY_MSG" > "$FAKE_PS_OUT"
STUB
chmod +x "$NS/fakeps"
env -i PATH=/usr/bin:/bin HOME="$HOME" NOTIFY_STATE_DIR="$NS/state" NOTIFY_POWERSHELL="$NS/fakeps" FAKE_PS_OUT="$NS/out" \
  /bin/bash "$ROOT/scripts/notify-operator.sh" "T1" "M1" k1 || fail "notify exit"
grep -q '^T1|M1$' "$NS/out" || fail "powershell not invoked under minimal PATH"
env -i PATH=/usr/bin:/bin HOME="$HOME" NOTIFY_STATE_DIR="$NS/state2" NOTIFY_POWERSHELL=/nonexistent/powershell.exe \
  /bin/bash "$ROOT/scripts/notify-operator.sh" "T2" "M2" k2 2>"$NS/err" || fail "notify must exit 0"
[[ -s "$NS/state2/.notify-undelivered" ]] && grep -q 'NOT DELIVERED' "$NS/err" || fail "undelivered notification was silent"
ok "notification: absolute powershell under cron PATH; undelivered leaves marker + log"

echo "ALL PASS"
