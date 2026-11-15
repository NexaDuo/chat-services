#!/usr/bin/env bash
# =============================================================================
# backup-host.sh — daily pg_dump of the stack DBs on the host-local production
# runtime (the Docker Compose stack served by the Cloudflare tunnel; see
# AGENTS.md "Deployment Strategy" and issue #109).
#
# This REPLACES scripts/vm-backup.sh, which uploaded to GCS via `gcloud` and is
# dead since GCP was decommissioned (commit b02aa74). Same guarantees:
#   - discovers the Postgres container and DBs dynamically (no hardcode);
#   - compressed pg_dump per DB (--clean --if-exists) into $BACKUP_DIR;
#   - local rotation by $BACKUP_KEEP_DAYS;
#   - FAILS if a critical DB (chatwoot, middleware) was not dumped — guards the
#     2026-06-25 silent-empty-dump class of incident;
#   - optional off-host copy via rclone ($BACKUP_RCLONE_REMOTE), so the dumps
#     survive host loss (the Postgres Docker volume is the SACRED data — a dump
#     that only lives on the same host is not a backup).
#
# Install (host cron, runs 03:00):
#   0 3 * * * BACKUP_RCLONE_REMOTE=onedrive:nexaduo/backups \
#     /path/to/repo/scripts/backup-host.sh >> /var/log/nexaduo-backup.log 2>&1
# scripts/run-stack.sh `backup` runs this on demand; `install-cron` installs it.
#
# IMPORTANT (DR): pg_dump is NOT a full backup. Docker volumes hold critical
# state NOT in any dump — Dify per-workspace RSA privkeys (encrypt the Azure
# OpenAI model-provider creds) and chatwoot-storage uploads. Losing them gives
# PrivkeyNotFoundError 500s (Dify) and ActiveStorage::FileNotFoundError 500s
# (Chatwoot avatars/attachments — issue #61) on a DB-only restore.
# This script therefore ALSO tars the critical Docker volumes (section 3b) into
# $BACKUP_DIR next to the dumps, rotates + off-host-copies them alongside the
# dumps, and (section 6) FAILS if a required volume archive is missing/empty and
# staleness-marks them so a silently-broken volume backup surfaces. See the
# AGENTS.md DR runbook for the restore side.
#
# IMPORTANT (single-env, issue #109): the host-local .env IS production config
# (secrets incl. TUNNEL_TOKEN, DB passwords, Azure OpenAI creds) and is
# deliberately NOT in git (see AGENTS.md "Inputs, operator-provided"). It is the
# one file a DB+volume restore alone can't reconstruct — without it a restored
# stack can't reach the tunnel or decrypt anything. Section 3c archives it
# alongside the dumps/volumes (same off-host treatment, no extra encryption —
# the off-host remote is assumed private/trusted, same as the DB dumps already
# shipped there) so it survives host loss. Issue #291 adds optional public-key
# encryption (BACKUP_GPG_RECIPIENT / BACKUP_AGE_RECIPIENT) for the .env and
# clone-secrets archives, a bounded wait for Docker, a verified off-host copy
# with remote retention, and failure notification (scripts/notify-operator.sh).
# =============================================================================
set -euo pipefail
# Everything this script writes (dumps, volume archives, secrets) is private.
umask 077

: "${BACKUP_DIR:=${HOME}/nexaduo-local/dumps}"
: "${POSTGRES_USER:=postgres}"
# Critical Docker volumes to archive (NOT captured by pg_dump). Matched by name
# SUFFIX so we tolerate the compose project prefix (chat-services_) differing per host.
#   chatwoot-storage    → Chatwoot uploads/avatars (issue #61 FileNotFoundError)
#   dify-api-storage    → Dify per-workspace RSA privkeys (PrivkeyNotFoundError)
#   evolution-instances → WhatsApp session/auth state (loss = re-scan QR code)
#   grafana-data        → Grafana users/custom dashboards not covered by provisioning
: "${BACKUP_VOLUME_SUFFIXES:=chatwoot-storage dify-api-storage evolution-instances grafana-data}"
: "${BACKUP_HELPER_IMAGE:=alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6}"  # tiny image to tar volumes read-only
: "${ENV_FILE:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env}"  # production secrets, not in git

: "${BACKUP_REPO_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${BACKUP_WAIT_INTERVAL:=30}"
SCRIPT_DIR_BH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[$(date -Is)] $*"; }

# Read one KEY from ENV_FILE WITHOUT sourcing it (run-stack.sh / cron do not load
# .env). Handles export, CRLF, whitespace, quotes and inline comments; the last
# assignment wins. Values are never logged.
env_file_get() {
  local k="$1" line v
  [[ -f "$ENV_FILE" ]] || return 0
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${k}[[:space:]]*=" "$ENV_FILE" | tail -n1 | tr -d '\r')" || true
  [[ -n "$line" ]] || return 0
  v="${line#*=}"; v="${v#"${v%%[![:space:]]*}"}"
  if [[ "$v" == \"* ]]; then v="${v#\"}"; v="${v%%\"*}"
  elif [[ "$v" == \'* ]]; then v="${v#\'}"; v="${v%%\'*}"
  else v="$(sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//' <<<"$v")"; fi
  printf '%s' "$v"
}
# A key UNSET in the process env is read from ENV_FILE; a key explicitly set
# (even to empty, e.g. BACKUP_RCLONE_REMOTE= to force local-only) is respected.
for _k in BACKUP_RCLONE_REMOTE BACKUP_GPG_RECIPIENT BACKUP_AGE_RECIPIENT BACKUP_KEEP_DAYS BACKUP_WAIT_SECONDS BACKUP_CLONE_SECRET_PATHS; do
  if [[ -z "${!_k+x}" ]]; then
    _v="$(env_file_get "$_k")"
    if [[ -n "$_v" ]]; then printf -v "$_k" '%s' "$_v"; log "${_k} resolvido de ENV_FILE."; fi
  fi
done
unset _k _v
: "${BACKUP_RCLONE_REMOTE:=}"          # e.g. onedrive:nexaduo/backups or a local path; empty = local-only
: "${BACKUP_GPG_RECIPIENT:=}"          # gpg full fingerprint (or email in keyring); encrypts secrets archives
: "${BACKUP_AGE_RECIPIENT:=}"          # age public key (preferred over gpg if `age` is installed)
: "${BACKUP_KEEP_DAYS:=14}"            # local AND remote retention
: "${BACKUP_WAIT_SECONDS:=1800}"       # bounded wait for Docker/Postgres (issue #291)
# Clone-local, git-ignored secrets/state (issue #291), relative to BACKUP_REPO_ROOT.
: "${BACKUP_CLONE_SECRET_PATHS:=.env deploy/.env infrastructure/terraform/envs/production/terraform.tfvars infrastructure/terraform/envs/foundation/terraform.tfvars infrastructure/terraform/envs/tenant/terraform.tfvars .claude/settings.local.json skills-lock.json}"
: "${BACKUP_CLONE_REQUIRED_PATHS:=.env}"   # missing => FAIL; other listed paths only warn

# Volumes that are legitimately EMPTY BY DESIGN, and therefore exempt ONLY
# from the minimum-size floor applied in section 6b below — NOT from the
# presence check there (a missing archive for one of these still fails the
# run). Deliberately a fixed, hardcoded array, not an env-overridable
# string: same documented-exception pattern and the same reasoning as the
# hardcoded `postgres` mem_limit exclusion (issue #157) and the fixed
# `HEALTHCHECK_COVERAGE_SKIP_SUBNAMES` array in health-check-all.sh (issue
# #158) — an env var here could silently widen the exemption from a stray
# shell export, exactly the "check that doesn't check" class both of those
# precedents were fixed to prevent.
#
#   evolution-instances → 2026-08-21: this Evolution API v2 deployment runs
#     with DATABASE_ENABLED (deploy/docker-compose.nexaduo.yml), which makes
#     it persist ALL instance/session/auth state (the `Instance`, `Session`,
#     `IntegrationSession` tables) in the `evolution` Postgres DB instead of
#     the filesystem — already covered by the evolution-*.sql.gz dump taken
#     in section 3 above. The volume is therefore genuinely empty (verified
#     live: `docker run --rm -v chat-services_evolution-instances:/data:ro
#     alpine find /data -mindepth 1 | wc -l` → 0), so its tar.gz is a
#     near-zero-byte gzip of an empty directory and legitimately trips the
#     size floor below.
#     `evolution-instances` stays in BACKUP_VOLUME_SUFFIXES on purpose,
#     rather than being removed from that list: if Evolution ever starts
#     writing to this volume again (a version bump, or DATABASE_ENABLED
#     flipped off), the archive keeps being taken every run and this guard
#     starts catching a truly-broken/empty archive again immediately —
#     removing the suffix instead would silently drop coverage for good.
BACKUP_EMPTY_OK_VOLUME_SUFFIXES=(evolution-instances)

# Pure decision function for the section-6b size guard, factored out so it
# can be exercised by a deterministic unit test
# (scripts/test-backup-volume-guard.sh) without running the rest of this
# script (which touches live Docker/Postgres). Returns 0 (should FAIL the
# run) or 1 (should NOT fail — either big enough, or small-but-allowlisted).
backup_volume_size_guard_should_fail() {
  local suffix="$1" sz="$2" min_bytes="$3"
  [[ "$sz" -lt "$min_bytes" ]] || return 1
  local allowed
  for allowed in "${BACKUP_EMPTY_OK_VOLUME_SUFFIXES[@]}"; do
    [[ "$suffix" == "$allowed" ]] && return 1
  done
  return 0
}

# Test-only early exit: BACKUP_HOST_TEST_MODE=1 lets
# scripts/test-backup-volume-guard.sh `source` this file to reuse the exact
# guard function/allowlist above (single source of truth) without executing
# any of the live-Docker/Postgres logic below.
# Sourced (the legitimate test path) -> return quietly. EXECUTED as a script
# with this var set is never legitimate: it would turn the nightly cron backup
# into a silent no-op exiting 0, which is a WORSE failure mode than the false
# positive this PR fixes (that one at least failed loudly). Fail loud instead,
# mirroring the SELF_HEALING_ALLOW_NO_CONFIG fail-loud precedent (AGENTS.md).
# Flagged independently by both the @sec and @rev pre-merge gates on PR #190.
if [[ "${BACKUP_HOST_TEST_MODE:-0}" == "1" ]]; then
  if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
  fi
  echo "ERRO: BACKUP_HOST_TEST_MODE=1 com o script EXECUTADO (nao sourceado)." >&2
  echo "      Essa variavel e exclusiva de scripts/test-backup-volume-guard.sh." >&2
  echo "      Abortando ruidosamente para nao mascarar um backup nao realizado." >&2
  exit 1
fi

# 1. Locate the Postgres container by its exact Compose name. Not by image
#    (the pin changes with upgrades) and not by a loose `name=postgres` match
#    (an upgrade rehearsal runs a throwaway "...-postgres" container too).
#    The 03:00 cron can fire while Docker Desktop is still down (issue #291: 30
#    days without a dump), so wait up to BACKUP_WAIT_SECONDS before failing.
assert_mode() { # path mode: verify, don't claim
  local got; got="$(stat -c%a "$1" 2>/dev/null || echo missing)"
  if [[ "$got" != "$2" ]]; then log "ERRO: permissão de '$1' é ${got}, esperado $2."; exit 1; fi
}
mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"; assert_mode "$BACKUP_DIR" 700
FAIL_MARKER="${BACKUP_DIR}/.backup-last-fail"
STAGE=""
PART=""   # in-flight .tmp-*.partial of THIS run (never a glob: a skipped run must not delete another run's)
on_exit() {
  local st=$?
  [[ -n "$PART" ]] && rm -f -- "$PART"
  [[ -n "$STAGE" ]] && rm -rf "$STAGE"
  if (( st != 0 )); then
    printf '[%s] FAIL: backup-host.sh exited %s (see cron log)\n' "$(date -Is)" "$st" > "$FAIL_MARKER" 2>/dev/null || true
    bash "$SCRIPT_DIR_BH/notify-operator.sh" "Backup FALHOU" "backup-host.sh saiu com codigo ${st}; ultimo dump pode estar velho." backup-host || true
  fi
}
trap on_exit EXIT
# Numeric settings: digits only, parsed base-10 (a leading zero must not become
# octal), bounded. Invalid values fail loudly instead of disabling the bounds.
num_setting() { # name min max
  local n="$1" v="${!1}"
  if ! [[ "$v" =~ ^[0-9]{1,7}$ ]] || (( 10#$v < $2 || 10#$v > $3 )); then
    log "ERRO: ${n} inválido ('${v}'); precisa ser inteiro decimal entre $2 e $3."
    exit 1
  fi
  printf -v "$n" '%s' "$((10#$v))"
}
num_setting BACKUP_KEEP_DAYS 1 3650           # 0 would empty the remote (and local)
num_setting BACKUP_WAIT_SECONDS 0 86400
num_setting BACKUP_WAIT_INTERVAL 1 3600
: "${BACKUP_STEP_TIMEOUT:=3600}"   # hard cap per long step (pg_dump, volume tar, rclone) so a hung run cannot hold the lock forever
num_setting BACKUP_STEP_TIMEOUT 1 86400
# One backup at a time (two overlapping runs could race quarantine vs upload).
# flock is released when the process dies, so a crashed run cannot leave it stuck.
exec 8>"${BACKUP_DIR}/.backup.lock"
flock -n 8 && lockrc=0 || lockrc=$?
if (( lockrc == 1 )); then
  # Contention (flock -n exits 1): skip, but leave a visible counter (.backup-skipped).
  _n=0
  [[ -f "${BACKUP_DIR}/.backup-skipped" ]] && _n="$(sed -n 's/^count=\([0-9]*\).*/\1/p' "${BACKUP_DIR}/.backup-skipped" | head -n1)"
  printf 'count=%s last=%s\n' "$(( ${_n:-0} + 1 ))" "$(date -Is)" > "${BACKUP_DIR}/.backup-skipped"
  log "AVISO: pulado: outro backup-host.sh mantém o lock (${BACKUP_DIR}/.backup-skipped registra o pulo)."
  trap - EXIT
  exit 0
elif (( lockrc != 0 )); then
  log "ERRO: flock falhou (status ${lockrc}); não é contenção."
  exit 1
fi

# Crash-safety (issue #299): every artifact is first written to a hidden
# ".tmp-<name>.partial" (matches no rotation/rclone/health-check pattern),
# verified, then renamed atomically. A run killed mid-write leaves only such
# partials (and a .stage.* dir); we hold the lock here so nothing else is
# writing, hence it is safe to delete them now.
find "$BACKUP_DIR" -maxdepth 1 -type f -name '.tmp-*.partial' -print -delete 2>/dev/null | sed 's/^/[backup] partial removido: /' || true
find "$BACKUP_DIR" -maxdepth 1 -type d -name '.stage.*' -exec rm -rf -- {} + 2>/dev/null || true

# Early validation of recipient and remote. NEVER blocks the LOCAL backup (the 30-day
# outage of #291 was "nothing got backed up"): a problem here is recorded in
# DEFER_ERRS, produces a loud warning now, skips only the off-host phase and the
# upload of secrets, and makes the run exit non-zero at the END.
DEFER_ERRS=()
SKIP_UPLOAD=0
LOCAL_STATUS=ok
ENC_MODE=none; ENC_ERR=""
RECIPIENT_SET=0; [[ -n "$BACKUP_AGE_RECIPIENT$BACKUP_GPG_RECIPIENT" ]] && RECIPIENT_SET=1
GPG_FPR_RE='^[0-9A-Fa-f]{40}$'
GPG_MAIL_RE='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$'
if [[ -n "$BACKUP_AGE_RECIPIENT" ]] && command -v age >/dev/null 2>&1; then
  ENC_MODE=age
elif [[ -n "$BACKUP_GPG_RECIPIENT" ]]; then
  if ! command -v gpg >/dev/null 2>&1; then
    ENC_ERR="BACKUP_GPG_RECIPIENT definido mas gpg não está instalado"
  elif ! [[ "$BACKUP_GPG_RECIPIENT" =~ $GPG_FPR_RE || "$BACKUP_GPG_RECIPIENT" =~ $GPG_MAIL_RE ]]; then
    ENC_ERR="BACKUP_GPG_RECIPIENT deve ser fingerprint completo (40 hex) ou email já presente no keyring"
  else
    # REAL check: an actual test encryption (no --trust-model always), so an imported
    # but untrusted/expired/unusable key fails here, not at 03:00 mid-run.
    _probe="$(mktemp "${BACKUP_DIR}/.probe.XXXXXX")"
    if printf 'probe' | timeout 60 gpg --batch --yes --quiet -r "$BACKUP_GPG_RECIPIENT" -o "$_probe" --encrypt >/dev/null 2>&1 && [[ -s "$_probe" ]]; then
      ENC_MODE=gpg
    else
      ENC_ERR="gpg não consegue criptografar para o recipient (chave ausente, não confiável ou expirada? importe a chave PÚBLICA e confie: gpg --edit-key <id> trust)"
    fi
    rm -f "$_probe"
  fi
elif [[ -n "$BACKUP_AGE_RECIPIENT" ]]; then
  ENC_ERR="BACKUP_AGE_RECIPIENT definido mas 'age' não está instalado (e sem BACKUP_GPG_RECIPIENT)"
fi
if [[ -n "$ENC_ERR" ]]; then
  ENC_MODE=broken; SKIP_UPLOAD=1
  DEFER_ERRS+=("criptografia: ${ENC_ERR}")
  log "ERRO: ${ENC_ERR}. O backup LOCAL continua; segredos ficam locais em texto plano, NADA vai off-host; o run terminará com falha."
elif [[ "$ENC_MODE" == none ]]; then
  log "AVISO: nenhum recipient de criptografia definido — arquivos de segredos (.env, clone-secrets) seguem em TEXTO PLANO (inclusive off-host)."
fi
if [[ -n "$BACKUP_RCLONE_REMOTE" ]]; then
  if ! command -v rclone >/dev/null 2>&1; then
    DEFER_ERRS+=("rclone não instalado"); SKIP_UPLOAD=1
    log "ERRO: BACKUP_RCLONE_REMOTE definido mas rclone não instalado. O backup LOCAL continua; off-host pulado."
  elif [[ "$BACKUP_RCLONE_REMOTE" == -* || "$BACKUP_RCLONE_REMOTE" == / || "$BACKUP_RCLONE_REMOTE" == "$HOME" ]]; then
    DEFER_ERRS+=("BACKUP_RCLONE_REMOTE inseguro"); SKIP_UPLOAD=1
    log "ERRO: BACKUP_RCLONE_REMOTE inseguro. O backup LOCAL continua; off-host pulado."
  # The destination must ALREADY exist (a missing local-path remote means the
  # OneDrive path is wrong or the drive is unmounted: rclone would silently mkdir it).
  elif _r="$(realpath -m -- "$BACKUP_RCLONE_REMOTE")"; _b="$(realpath -m -- "$BACKUP_DIR")"; \
       [[ "$_r" == "$_b" || "$_r" == "$_b"/* || "$_b" == "$_r"/* ]]; then
    DEFER_ERRS+=("remote sobrepõe BACKUP_DIR"); SKIP_UPLOAD=1
    log "ERRO: BACKUP_RCLONE_REMOTE igual/dentro/acima de BACKUP_DIR (não é off-host). O backup LOCAL continua; off-host pulado."
  elif ! timeout 120 rclone lsf "$BACKUP_RCLONE_REMOTE" --max-depth 1 >/dev/null 2>&1; then
    DEFER_ERRS+=("remote inexistente/inacessível"); SKIP_UPLOAD=1
    log "ERRO: remote '${BACKUP_RCLONE_REMOTE}' inexistente/inacessível (caminho errado ou drive não montado?). O backup LOCAL continua; off-host pulado; o run terminará com falha."
  fi
fi

# Wait until Postgres ACCEPTS connections, not merely until the container is
# listed (Docker Desktop just up / WAL recovery). Docker CLI calls are bounded.
# Clock and sleep are injectable so tests are deterministic.
# The hooks are honored ONLY with BACKUP_TEST_MODE=1 (loud warning), else always
# `date +%s` / `sleep`: no env-supplied command runs on the production path.
if [[ "${BACKUP_TEST_MODE:-0}" == "1" ]]; then
  log "AVISO: BACKUP_TEST_MODE=1 — hooks de clock/sleep de TESTE ativos (nunca em produção)."
  BACKUP_CLOCK_CMD="${BACKUP_CLOCK_CMD:-date +%s}"; BACKUP_SLEEP_CMD="${BACKUP_SLEEP_CMD:-sleep}"
else
  BACKUP_CLOCK_CMD="date +%s"; BACKUP_SLEEP_CMD="sleep"
fi
WAIT_START="$($BACKUP_CLOCK_CMD)"
PG=""
while :; do
  PG="$(timeout 20 docker ps --filter "name=^/${COMPOSE_PROJECT_NAME:-chat-services}-postgres-1$" --format '{{.Names}}' 2>/dev/null | head -n1)" || PG=""
  if [[ -n "$PG" ]] && timeout 20 docker exec "$PG" pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1; then break; fi
  WAITED=$(( $($BACKUP_CLOCK_CMD) - WAIT_START ))
  if (( WAITED >= BACKUP_WAIT_SECONDS )); then
    log "ERRO: Postgres (${COMPOSE_PROJECT_NAME:-chat-services}-postgres-1) indisponível após ${BACKUP_WAIT_SECONDS}s de espera."
    exit 1
  fi
  log "Docker/Postgres indisponível; nova tentativa em ${BACKUP_WAIT_INTERVAL}s (${WAITED}s/${BACKUP_WAIT_SECONDS}s)."
  $BACKUP_SLEEP_CMD "$BACKUP_WAIT_INTERVAL"
done
log "Container Postgres: $PG"

# 2. Discover application DBs (exclude Postgres internals).
mapfile -t DBS < <(timeout 120 docker exec "$PG" psql -U "$POSTGRES_USER" -tAc \
  "SELECT datname FROM pg_database WHERE datname NOT IN ('postgres','template0','template1') ORDER BY datname")
if [[ ${#DBS[@]} -eq 0 ]]; then
  log "ERRO: nenhum DB de aplicação encontrado."
  exit 1
fi
# Names end up in file names and rclone globs: only [A-Za-z0-9_.-] are accepted.
NAME_RE='^[A-Za-z0-9_.-]+$'
_good=()
for DB in "${DBS[@]}"; do
  if [[ "$DB" =~ $NAME_RE ]]; then _good+=("$DB")
  else
    log "ERRO: nome de DB fora de ${NAME_RE} ignorado (NÃO será backupado): ${DB@Q}"
    DEFER_ERRS+=("DB com nome inválido ignorado"); LOCAL_STATUS=partial
  fi
done
DBS=("${_good[@]}")
if [[ ${#DBS[@]} -eq 0 ]]; then log "ERRO: nenhum DB de aplicação válido."; exit 1; fi
log "DBs a backupar: ${DBS[*]}"

TS="$(date +%F-%H%M)"
mkdir -p "$BACKUP_DIR"

# 3. Dump per DB.
FILES=()
for DB in "${DBS[@]}"; do
  OUT="${BACKUP_DIR}/${DB}-${TS}.sql.gz"
  PART="${BACKUP_DIR}/.tmp-${DB}-${TS}.sql.gz.partial"
  log "==> Dumping ${DB} → ${OUT}"
  timeout -k 5 "$BACKUP_STEP_TIMEOUT" docker exec "$PG" pg_dump -U "$POSTGRES_USER" -d "$DB" --no-owner --clean --if-exists \
    | gzip -9 > "$PART" || { log "ERRO: pg_dump de ${DB} falhou/estourou o timeout; removendo dump parcial."; rm -f "$PART"; exit 1; }
  # Verify before it can ever carry the final name (gzip integrity + non-empty).
  if ! [[ -s "$PART" ]] || ! gzip -t "$PART" 2>/dev/null; then
    log "ERRO: dump de ${DB} vazio/corrompido (gzip -t); removendo."; rm -f "$PART"; exit 1
  fi
  mv -f "$PART" "$OUT"
  FILES+=("$OUT")
done

# 3b. Archive critical Docker volumes (NOT captured by pg_dump). We tar each
# volume read-only via a throwaway helper container so the archive is complete
# even if the consuming service is down. Resolve each configured suffix to a
# real volume name (tolerates the compose project prefix). Missing volumes are
# recorded so the section-6 coverage check can FAIL on them.
VOL_FILES=()
RESOLVED_VOLS=()
MISSING_VOLS=()
for suffix in $BACKUP_VOLUME_SUFFIXES; do
  vol="$(timeout 60 docker volume ls --format '{{.Name}}' | grep -E "(^|_)${suffix}\$" | head -n1)"
  if [[ -z "$vol" ]]; then
    log "AVISO: volume crítico com sufixo '${suffix}' não encontrado (docker volume ls)."
    MISSING_VOLS+=("$suffix")
    continue
  fi
  if ! [[ "$vol" =~ $NAME_RE ]]; then
    log "ERRO: nome de volume fora de ${NAME_RE} ignorado: ${vol@Q}"
    MISSING_VOLS+=("$suffix"); DEFER_ERRS+=("volume com nome inválido ignorado"); LOCAL_STATUS=partial
    continue
  fi
  OUT="${BACKUP_DIR}/${vol}-${TS}.tar.gz"
  log "==> Archiving volume ${vol} → ${OUT}"
  # -v <vol>:/data:ro read-only source; write the tarball to STDOUT and land it
  # on the host so we never need a host bind-mount to be writable by the image.
  # Named container so a timed-out run can be force-removed (killing the docker CLI alone
  # would leave the helper container running). pg_dump: killing the `docker exec` client
  # closes its stdout, so the server-side pg_dump dies on SIGPIPE at its next write.
  cname="nexaduo-backup-${vol}-$$"
  PART="${BACKUP_DIR}/.tmp-${vol}-${TS}.tar.gz.partial"
  if timeout -k 5 "$BACKUP_STEP_TIMEOUT" docker run --rm --name "$cname" -v "${vol}:/data:ro" "$BACKUP_HELPER_IMAGE" \
        tar czf - -C /data . > "$PART" 2>/dev/null && [[ -s "$PART" ]] && tar -tzf "$PART" >/dev/null 2>&1; then
    mv -f "$PART" "$OUT"
    VOL_FILES+=("$OUT")
    RESOLVED_VOLS+=("$vol")
  else
    log "ERRO: falha ao arquivar volume ${vol} (tar/helper image ${BACKUP_HELPER_IMAGE})."
    timeout 30 docker rm -f "$cname" >/dev/null 2>&1 || true
    rm -f "$PART" 2>/dev/null || true
    MISSING_VOLS+=("$suffix")
  fi
done

# Secrets archives (env-*, clone-secrets-*). With a recipient the tarball is
# piped straight into the encryptor and written to a temp name inside a 0700
# staging dir; it enters BACKUP_DIR only after success, so a failed encryption can
# never leave (or upload) a plaintext archive. Public-key only: cron stays
# unattended and no passphrase touches disk. age is preferred if installed.
# A configured recipient with no usable tool/key FAILS the run, never plaintext.
STAGE="$(mktemp -d "${BACKUP_DIR}/.stage.XXXXXX")"; chmod 700 "$STAGE"

# do_secret_archive <outvar> <basename.tar.gz> <tar args...>: runs in the MAIN shell. If
# encryption fails mid-run the local archive is still taken (plaintext, 0600, local only),
# encryption is marked broken, the upload is skipped and the run will end non-zero.
do_secret_archive() {
  local __v="$1" __out; shift
  if ! __out="$(make_secret_archive "$@")"; then
    if [[ "$ENC_MODE" == gpg || "$ENC_MODE" == age ]]; then
      log "ERRO: criptografia falhou durante o run; segredos locais em TEXTO PLANO (0600), NADA off-host."
      ENC_MODE=broken; SKIP_UPLOAD=1; DEFER_ERRS+=("criptografia falhou durante o run")
      __out="$(make_secret_archive "$@")" || return 1
    else
      return 1
    fi
  fi
  printf -v "$__v" '%s' "$__out"
}
# make_secret_archive <basename.tar.gz> <tar args...> -> prints final path.
make_secret_archive() {
  local name="$1"; shift
  local tmp="${STAGE}/.tmp-${name}.partial" final="${BACKUP_DIR}/${name}"
  # PLAINTEXT FALLBACK (encryption configured but broken): goes into quarantine-plaintext/,
  # a location NO upload filter can ever match, regardless of what later runs resolve.
  # (Plaintext by design, with NO recipient configured, keeps the normal upload-eligible name.)
  if [[ "$ENC_MODE" == broken ]]; then
    mkdir -p "$BACKUP_DIR/quarantine-plaintext"; chmod 700 "$BACKUP_DIR/quarantine-plaintext"
    assert_mode "$BACKUP_DIR/quarantine-plaintext" 700
    final="$BACKUP_DIR/quarantine-plaintext/${name}"
  fi
  case "$ENC_MODE" in
    age) final="${final}.age"; tar czhf - "$@" | timeout 300 age -r "$BACKUP_AGE_RECIPIENT" -o "$tmp" || { rm -f "$tmp"; return 1; } ;;
    gpg) final="${final}.gpg"; tar czhf - "$@" | timeout 300 gpg --batch --yes --quiet -r "$BACKUP_GPG_RECIPIENT" -o "$tmp" --encrypt || { rm -f "$tmp"; return 1; } ;;
    *)   tar czhf "$tmp" "$@" || { rm -f "$tmp"; return 1; } ;;
  esac
  [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
  # Integrity: plaintext archives are checkable; encrypted ones only for non-empty here.
  if [[ "$ENC_MODE" != age && "$ENC_MODE" != gpg ]]; then tar -tzf "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }; fi
  chmod 600 "$tmp"; mv -f "$tmp" "$final"; assert_mode "$final" 600
  printf '%s' "$final"
}

# With a recipient set, plaintext env-*/clone-secrets-* left by earlier runs must
# never be uploaded: quarantine them locally (rotation still ages them out).
if [[ "$ENC_MODE" == gpg || "$ENC_MODE" == age ]]; then
  shopt -s nullglob
  for _f in "$BACKUP_DIR"/env-*.tar.gz "$BACKUP_DIR"/clone-secrets-*.tar.gz; do
    mkdir -p "$BACKUP_DIR/quarantine-plaintext"; chmod 700 "$BACKUP_DIR/quarantine-plaintext"; assert_mode "$BACKUP_DIR/quarantine-plaintext" 700
    mv -f "$_f" "$BACKUP_DIR/quarantine-plaintext/"
    log "AVISO: arquivo de segredos em TEXTO PLANO pré-existente '$(basename "$_f")' movido para quarantine-plaintext/ (NÃO será enviado off-host)."
  done
  shopt -u nullglob
fi

if [[ "$ENC_MODE" == broken ]]; then
  log "AVISO: criptografia inoperante: arquivos de segredos locais ficam em TEXTO PLANO em quarantine-plaintext/ (0600, dir 0700) e NUNCA são enviados off-host."
fi
# 3c. Archive the host .env (production secrets, not in git — see header).
ENV_FILE_OUT=""
if [[ -f "$ENV_FILE" ]]; then
  log "==> Archiving ${ENV_FILE} → ${BACKUP_DIR}/env-${TS}.tar.gz[.age|.gpg]"
  do_secret_archive ENV_FILE_OUT "env-${TS}.tar.gz" -C "$(dirname "$ENV_FILE")" -- "$(basename "$ENV_FILE")" \
    || { log "ERRO: falha ao arquivar/criptografar o .env (nada foi mantido em texto plano)."; exit 1; }
else
  log "AVISO: ENV_FILE (${ENV_FILE}) não encontrado — .env NÃO foi arquivado neste run."
fi

# 3d. Archive the clone-local secrets allowlist (issue #291): git-ignored files
# that exist only in this clone. Explicit allowlist, no globbing; entries must be
# relative, without `..`/leading `-`, and (after symlink resolution) inside the repo.
CLONE_OUT=""
CLONE_PRESENT=()
CLONE_REQ_MISSING=0
ROOT_REAL="$(realpath -- "$BACKUP_REPO_ROOT")"
set -f
for p in $BACKUP_CLONE_SECRET_PATHS; do
  if [[ "$p" == /* || "$p" == -* || "$p" == *..* || "$p" == *[\*\?\[]* ]]; then
    log "ERRO: entrada inválida em BACKUP_CLONE_SECRET_PATHS: '${p}' (sem absoluto, '..', glob ou '-' inicial)."
    CLONE_REQ_MISSING=1; continue
  fi
  if [[ -e "${BACKUP_REPO_ROOT}/${p}" ]]; then
    real="$(realpath -- "${BACKUP_REPO_ROOT}/${p}")"
    if [[ "$real" != "$ROOT_REAL"/* ]]; then
      log "ERRO: '${p}' resolve para fora do repositório; não será arquivado."
      CLONE_REQ_MISSING=1; continue
    fi
    [[ -f "$real" ]] && CLONE_PRESENT+=("$p")
  elif [[ " $BACKUP_CLONE_REQUIRED_PATHS " == *" $p "* ]]; then
    log "ERRO: arquivo obrigatório '${p}' ausente em ${BACKUP_REPO_ROOT} (clone-secrets)."
    CLONE_REQ_MISSING=1
  else
    log "AVISO: '${p}' ausente (opcional) — não incluído em clone-secrets."
  fi
done
set +f
if (( CLONE_REQ_MISSING == 0 && ${#CLONE_PRESENT[@]} > 0 )); then
  log "==> Archiving clone-local secrets (${#CLONE_PRESENT[@]} arquivos) → ${BACKUP_DIR}/clone-secrets-${TS}.tar.gz[.age|.gpg]"
  do_secret_archive CLONE_OUT "clone-secrets-${TS}.tar.gz" -C "$BACKUP_REPO_ROOT" -- "${CLONE_PRESENT[@]}" \
    || { log "ERRO: falha ao arquivar/criptografar clone-secrets (nada foi mantido em texto plano)."; exit 1; }
fi

# 4. Local rotation (dumps + volume archives + .env archive).
log "==> Limpando backups locais com mais de ${BACKUP_KEEP_DAYS} dias"
find "$BACKUP_DIR" -type f \( -name '*.sql.gz' -o -name '*.tar.gz' -o -name '*.tar.gz.gpg' -o -name '*.tar.gz.age' \) -mtime +"$BACKUP_KEEP_DAYS" -print -delete || true

# 5. Off-host copy (optional but strongly recommended — host loss = data loss).
# No --max-age: a missed day must still sync everything not yet remote (rclone
# skips identical files). Presence/size is verified in 6d; remote retention
# (matching BACKUP_KEEP_DAYS, so e.g. a OneDrive/C: folder cannot fill up) runs
# only AFTER that verification passed.
# Filters: ONE ordered --filter list (first matching rule wins; real rclone
# evaluates --include before --exclude, so never mix those). Anchored at the remote
# root, top level only (--max-depth 1), digit classes for the timestamp, and limited
# to the exact prefixes this script generates (<db>-, <volume>-, env-, clone-secrets-),
# so foreign files in the target folder are never overwritten nor pruned. With a
# recipient set, plaintext env-/clone-secrets- archives are excluded FIRST.
D='[0-9]'; TSG="${D}${D}${D}${D}-${D}${D}-${D}${D}-${D}${D}${D}${D}"
RCLONE_FILTERS=(--filter '- /quarantine-plaintext/**')   # unconditional: the quarantine is never uploaded
if (( RECIPIENT_SET )); then   # also when encryption is broken: plaintext secrets never leave the host
  RCLONE_FILTERS+=(--filter '- /env-*.tar.gz' --filter '- /clone-secrets-*.tar.gz')
fi
for _db in "${DBS[@]}"; do RCLONE_FILTERS+=(--filter "+ /${_db}-${TSG}.sql.gz"); done
for _v in "${RESOLVED_VOLS[@]}"; do RCLONE_FILTERS+=(--filter "+ /${_v}-${TSG}.tar.gz"); done
for _pfx in env clone-secrets; do
  RCLONE_FILTERS+=(--filter "+ /${_pfx}-${TSG}.tar.gz" --filter "+ /${_pfx}-${TSG}.tar.gz.gpg" --filter "+ /${_pfx}-${TSG}.tar.gz.age")
done
RCLONE_FILTERS+=(--filter '- *' --max-depth 1)
# Selector for ONLY the plaintext secrets archives (listing/deleting them).
RCLONE_PLAIN_SECRETS=(--filter "+ /env-${TSG}.tar.gz" --filter "+ /clone-secrets-${TSG}.tar.gz" --filter '- *' --max-depth 1)
OFFHOST_OK=none
UPLOADED=0
_plain_remote=""
if [[ -z "$BACKUP_RCLONE_REMOTE" ]]; then
  log "AVISO: BACKUP_RCLONE_REMOTE não definido — dumps ficam SÓ neste host (não é backup real)."
elif (( SKIP_UPLOAD )); then
  OFFHOST_OK=failed
  log "AVISO: off-host PULADO por falha de pré-validação; backup local mantido."
else
  if [[ "$ENC_MODE" == gpg || "$ENC_MODE" == age ]]; then
    _plain_remote="$(timeout 600 rclone lsf "$BACKUP_RCLONE_REMOTE" "${RCLONE_PLAIN_SECRETS[@]}" 2>/dev/null || true)"
    if [[ -n "$_plain_remote" ]]; then
      log "AVISO: segredos em TEXTO PLANO já existem no remote: $(tr '\n' ' ' <<<"$_plain_remote") — serão removidos SOMENTE após a verificação do substituto criptografado deste run (purgue também a lixeira/versões do OneDrive)."
    fi
    _odd="$(timeout 600 rclone lsf "$BACKUP_RCLONE_REMOTE" --filter '+ /env-*.tar.gz' --filter '+ /clone-secrets-*.tar.gz' --filter '- *' --max-depth 1 2>/dev/null \
            | grep -vxFf <(printf '%s\n' "$_plain_remote") || true)"
    [[ -z "$_odd" ]] || log "AVISO: possíveis segredos em TEXTO PLANO com nome fora do padrão no remote (NÃO removidos; verifique à mão): $(tr '\n' ' ' <<<"$_odd")"
  fi
  log "==> Copiando para ${BACKUP_RCLONE_REMOTE} via rclone (dumps + volumes + .env + clone-secrets)"
  if timeout -k 5 "$BACKUP_STEP_TIMEOUT" rclone copy "$BACKUP_DIR" "$BACKUP_RCLONE_REMOTE" "${RCLONE_FILTERS[@]}"; then
    UPLOADED=1
  else
    log "ERRO: rclone copy falhou/estourou o timeout."
    DEFER_ERRS+=("rclone copy falhou"); OFFHOST_OK=failed
  fi
fi

# 6. Critical-DB coverage check (post-2026-06-25 safeguard). Exit non-zero if a
# customer-data DB is missing/suspiciously small so it surfaces in the cron log.
CRITICAL_DBS=(${BACKUP_REQUIRED_DBS:-chatwoot middleware})
MIN_BYTES="${BACKUP_MIN_BYTES:-1000}"
missing=0
for DB in "${CRITICAL_DBS[@]}"; do
  f="${BACKUP_DIR}/${DB}-${TS}.sql.gz"
  if [[ ! -f "$f" ]]; then
    log "ERRO: DB crítico '${DB}' NÃO foi dumpado (arquivo ausente). Existe no Postgres?"
    missing=1
    continue
  fi
  sz="$(stat -c%s "$f" 2>/dev/null || echo 0)"
  if [[ "$sz" -lt "$MIN_BYTES" ]]; then
    log "ERRO: dump de '${DB}' suspeito (${sz} bytes < ${MIN_BYTES})."
    missing=1
  fi
done
if [[ "$missing" -ne 0 ]]; then
  log "==> FALHA: cobertura de backup incompleta para DBs críticos (${CRITICAL_DBS[*]})."
  exit 1
fi

# 6b. Critical-volume coverage check (issue #61). A pg_dump that "succeeds" while
# the chatwoot-storage / dify-api-storage volumes went un-archived is the exact
# silent gap that produced this incident — so treat a missing/empty required
# volume archive as a hard failure that surfaces in the cron log.
#
# The size-floor decision itself (small-but-legitimately-empty vs.
# genuinely-suspicious) is delegated to backup_volume_size_guard_should_fail()
# defined near the top of this file, so BACKUP_EMPTY_OK_VOLUME_SUFFIXES (see
# its comment there for the evolution-instances rationale) has a single
# source of truth shared with scripts/test-backup-volume-guard.sh.
REQUIRED_VOL_SUFFIXES=(${BACKUP_REQUIRED_VOLUME_SUFFIXES:-$BACKUP_VOLUME_SUFFIXES})
# A gzipped tar of a tiny (privkey) volume is legitimately small; use a lower
# floor than the DB dump one but still non-empty (an empty/errored tar is ~<50B).
VOL_MIN_BYTES="${BACKUP_VOLUME_MIN_BYTES:-100}"
vol_missing=0
for suffix in "${REQUIRED_VOL_SUFFIXES[@]}"; do
  f="$(ls -1t "${BACKUP_DIR}"/*"${suffix}"-"${TS}".tar.gz 2>/dev/null | head -n1)"
  if [[ -z "$f" || ! -f "$f" ]]; then
    log "ERRO: volume crítico '${suffix}' NÃO foi arquivado neste run (tar.gz ausente)."
    vol_missing=1
    continue
  fi
  sz="$(stat -c%s "$f" 2>/dev/null || echo 0)"
  if backup_volume_size_guard_should_fail "$suffix" "$sz" "$VOL_MIN_BYTES"; then
    log "ERRO: arquivo de volume '${suffix}' suspeito (${sz} bytes < ${VOL_MIN_BYTES})."
    vol_missing=1
  elif [[ "$sz" -lt "$VOL_MIN_BYTES" ]]; then
    log "AVISO: arquivo de volume '${suffix}' pequeno (${sz} bytes < ${VOL_MIN_BYTES}) mas está na allowlist de vazio-por-design (BACKUP_EMPTY_OK_VOLUME_SUFFIXES) — não falha o guard."
  fi
done
if [[ "$vol_missing" -ne 0 ]]; then
  log "==> FALHA: cobertura de backup de VOLUMES incompleta (${REQUIRED_VOL_SUFFIXES[*]})."
  exit 1
fi

# 6c. .env coverage check — losing this file is fatal for a from-scratch restore
# (no secrets = can't reach the tunnel, decrypt nothing, reconnect no DB), so
# treat a missing/empty archive as a hard failure like the DB/volume checks above.
ENV_MIN_BYTES="${BACKUP_ENV_MIN_BYTES:-100}"
if [[ -z "$ENV_FILE_OUT" || ! -f "$ENV_FILE_OUT" ]]; then
  log "ERRO: .env NÃO foi arquivado neste run (tar.gz ausente)."
  exit 1
fi
env_sz="$(stat -c%s "$ENV_FILE_OUT" 2>/dev/null || echo 0)"
if [[ "$env_sz" -lt "$ENV_MIN_BYTES" ]]; then
  log "ERRO: arquivo de .env suspeito (${env_sz} bytes < ${ENV_MIN_BYTES})."
  exit 1
fi

# 6d. Off-host verification: every file produced by THIS run must be on the
# remote with the same size. Only then prune the remote past the retention window.
# Failures here are DEFERRED (local backup already complete): .last-success records
# offhost=failed and the run exits non-zero at the end.
if (( UPLOADED )); then
  off_bad=0; off_checked=0
  remote_listing="$(timeout 600 rclone lsf "$BACKUP_RCLONE_REMOTE" --format 'ps' --separator ';' "${RCLONE_FILTERS[@]}")" || { remote_listing=""; off_bad=1; }
  for f in "${FILES[@]}" "${VOL_FILES[@]}" "$ENV_FILE_OUT" "$CLONE_OUT"; do
    [[ -n "$f" ]] || continue
    off_checked=$((off_checked+1))
    want="$(basename "$f");$(stat -c%s "$f")"
    if ! grep -Fxq -- "$want" <<<"$remote_listing"; then
      log "ERRO: off-host sem '$(basename "$f")' com o tamanho local (remote: ${BACKUP_RCLONE_REMOTE})."
      off_bad=1
    fi
  done
  if (( off_bad || off_checked == 0 )); then
    log "==> FALHA: verificação off-host incompleta (nenhuma poda/remoção feita)."
    DEFER_ERRS+=("verificação off-host incompleta"); OFFHOST_OK=failed
  else
    OFFHOST_OK=verified
    # Remote archives outside this run's DB/volume set are never pruned: just warn.
    _broad="$(timeout 600 rclone lsf "$BACKUP_RCLONE_REMOTE" --filter '- /env-*' --filter '- /clone-secrets-*' --filter "+ /*-${TSG}.sql.gz" --filter "+ /*-${TSG}.tar.gz" --filter '- *' --max-depth 1 2>/dev/null || true)"
    _ours="$(timeout 600 rclone lsf "$BACKUP_RCLONE_REMOTE" "${RCLONE_FILTERS[@]}" 2>/dev/null || true)"
    _stale="$(grep -vxFf <(printf '%s\n' "$_ours") <<<"$_broad" || true)"
    [[ -z "$_stale" ]] || log "AVISO: remote tem arquivos de DB/volume fora do conjunto atual (removido/renomeado?), NÃO podados: $(tr '\n' ' ' <<<"$_stale")"
    log "==> Off-host verificado; podando remote com mais de ${BACKUP_KEEP_DAYS} dias"
    timeout -k 5 "$BACKUP_STEP_TIMEOUT" rclone delete "$BACKUP_RCLONE_REMOTE" --min-age "${BACKUP_KEEP_DAYS}d" "${RCLONE_FILTERS[@]}" \
      || DEFER_ERRS+=("poda do remote falhou")
    # Plaintext secrets already on the remote: delete ONLY when a recipient is set AND
    # this run's encrypted env + clone-secrets archives were just verified remotely.
    if [[ ( "$ENC_MODE" == gpg || "$ENC_MODE" == age ) && -n "$_plain_remote" && -n "$ENV_FILE_OUT" && -n "$CLONE_OUT" ]]; then
      log "==> Removendo do remote os segredos em TEXTO PLANO (substitutos criptografados verificados): $(tr '\n' ' ' <<<"$_plain_remote")"
      timeout -k 5 "$BACKUP_STEP_TIMEOUT" rclone delete "$BACKUP_RCLONE_REMOTE" "${RCLONE_PLAIN_SECRETS[@]}" \
        || DEFER_ERRS+=("remoção de plaintext remoto falhou")
    fi
  fi
fi

# 6e. clone-secrets coverage: required file missing or archive absent = hard failure.
if (( CLONE_REQ_MISSING )) || [[ -z "$CLONE_OUT" || ! -s "$CLONE_OUT" ]]; then
  log "ERRO: clone-secrets NÃO foi arquivado neste run."
  exit 1
fi

# 7. Success marker (issue #121): write a timestamped marker ONLY on full
# success so health-check-all.sh / self-healing can detect a stale or failed
# backup unambiguously (a failing cron leaves this marker old). The .sql.gz
# mtime is the primary signal; this is the explicit belt-and-suspenders record.
MARKER="${BACKUP_DIR}/.last-success"
# Written when the LOCAL backup is complete, even if the off-host phase failed:
# `local=ok offhost=failed reason=...` lets health-check-all.sh tell "local fresh,
# off-host broken" (restore possible) from "nothing fresh".
_reason=""; (( ${#DEFER_ERRS[@]} )) && _reason="$(printf '%s; ' "${DEFER_ERRS[@]}" | tr -c 'A-Za-z0-9_.:;/ -' '_')"
{ echo "$(date -Is)";
  echo "dbs=${#FILES[@]} critical_ok=${CRITICAL_DBS[*]} rclone=${BACKUP_RCLONE_REMOTE:-none}";
  echo "volumes=${#VOL_FILES[@]} archived=${RESOLVED_VOLS[*]:-none} required=${REQUIRED_VOL_SUFFIXES[*]}";
  echo "env=${ENV_FILE_OUT:-none}";
  echo "local=${LOCAL_STATUS} clone_secrets=${CLONE_OUT:-none} encrypted=${ENC_MODE} offhost=${OFFHOST_OK}${_reason:+ reason=${_reason}}"; } > "$MARKER" || \
  log "AVISO: não consegui escrever marker de sucesso em $MARKER"

if (( ${#DEFER_ERRS[@]} )); then
  log "==> FALHA (backup LOCAL completo; problema off-host/criptografia/nomes): ${DEFER_ERRS[*]}"
  exit 1   # on_exit writes .backup-last-fail and notifies
fi
rm -f "$FAIL_MARKER" "${BACKUP_DIR}/.backup-skipped"
log "==> Backup concluído (${#FILES[@]} DBs, ${#VOL_FILES[@]} volumes, .env; críticos OK: DBs=${CRITICAL_DBS[*]}, vols=${REQUIRED_VOL_SUFFIXES[*]})."
