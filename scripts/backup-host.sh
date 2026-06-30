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
# PrivkeyNotFoundError 500s on restore. Periodically also archive the Docker
# volumes (see scripts/run-stack.sh `backup-volumes`). See AGENTS.md DR runbook.
# =============================================================================
set -euo pipefail

: "${BACKUP_DIR:=${HOME}/nexaduo-local/dumps}"
: "${BACKUP_KEEP_DAYS:=14}"
: "${POSTGRES_USER:=postgres}"
: "${BACKUP_RCLONE_REMOTE:=}"   # e.g. onedrive:nexaduo/backups; empty = local-only

log() { echo "[$(date -Is)] $*"; }

# 1. Locate the Postgres container (compose name nexaduo-postgres-1, or by image).
PG="$(docker ps --filter 'name=postgres' --filter 'ancestor=pgvector/pgvector:pg16' --format '{{.Names}}' | head -n1)"
if [[ -z "$PG" ]]; then
  PG="$(docker ps --filter 'name=^/nexaduo-postgres' --format '{{.Names}}' | head -n1)"
fi
if [[ -z "$PG" ]]; then
  log "ERRO: container Postgres não encontrado (docker ps name=postgres)."
  exit 1
fi
log "Container Postgres: $PG"

# 2. Discover application DBs (exclude Postgres internals).
mapfile -t DBS < <(docker exec "$PG" psql -U "$POSTGRES_USER" -tAc \
  "SELECT datname FROM pg_database WHERE datname NOT IN ('postgres','template0','template1') ORDER BY datname")
if [[ ${#DBS[@]} -eq 0 ]]; then
  log "ERRO: nenhum DB de aplicação encontrado."
  exit 1
fi
log "DBs a backupar: ${DBS[*]}"

TS="$(date +%F-%H%M)"
mkdir -p "$BACKUP_DIR"

# 3. Dump per DB.
FILES=()
for DB in "${DBS[@]}"; do
  OUT="${BACKUP_DIR}/${DB}-${TS}.sql.gz"
  log "==> Dumping ${DB} → ${OUT}"
  docker exec "$PG" pg_dump -U "$POSTGRES_USER" -d "$DB" --no-owner --clean --if-exists \
    | gzip -9 > "$OUT"
  FILES+=("$OUT")
done

# 4. Local rotation.
log "==> Limpando backups locais com mais de ${BACKUP_KEEP_DAYS} dias"
find "$BACKUP_DIR" -type f -name '*.sql.gz' -mtime +"$BACKUP_KEEP_DAYS" -print -delete || true

# 5. Off-host copy (optional but strongly recommended — host loss = data loss).
if [[ -n "$BACKUP_RCLONE_REMOTE" ]]; then
  if command -v rclone >/dev/null 2>&1; then
    log "==> Copiando para ${BACKUP_RCLONE_REMOTE} via rclone"
    rclone copy "$BACKUP_DIR" "$BACKUP_RCLONE_REMOTE" --include '*.sql.gz' --max-age 25h
  else
    log "AVISO: BACKUP_RCLONE_REMOTE definido mas rclone não instalado — pulando off-host copy."
  fi
else
  log "AVISO: BACKUP_RCLONE_REMOTE não definido — dumps ficam SÓ neste host (não é backup real)."
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

log "==> Backup concluído (${#FILES[@]} DBs; críticos OK: ${CRITICAL_DBS[*]})."
