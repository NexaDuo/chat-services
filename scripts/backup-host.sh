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
# =============================================================================
set -euo pipefail

: "${BACKUP_DIR:=${HOME}/nexaduo-local/dumps}"
: "${BACKUP_KEEP_DAYS:=14}"
: "${POSTGRES_USER:=postgres}"
: "${BACKUP_RCLONE_REMOTE:=}"   # e.g. onedrive:nexaduo/backups; empty = local-only
# Critical Docker volumes to archive (NOT captured by pg_dump). Matched by name
# SUFFIX so we tolerate the compose project prefix (chat-services_) differing per host.
#   chatwoot-storage    → Chatwoot uploads/avatars (issue #61 FileNotFoundError)
#   dify-api-storage    → Dify per-workspace RSA privkeys (PrivkeyNotFoundError)
#   evolution-instances → WhatsApp session/auth state (loss = re-scan QR code)
#   grafana-data        → Grafana users/custom dashboards not covered by provisioning
: "${BACKUP_VOLUME_SUFFIXES:=chatwoot-storage dify-api-storage evolution-instances grafana-data}"
: "${BACKUP_HELPER_IMAGE:=alpine:3.20}"  # tiny image to tar volumes read-only

log() { echo "[$(date -Is)] $*"; }

# 1. Locate the Postgres container (compose name chat-services-postgres-1, or by image).
PG="$(docker ps --filter 'name=postgres' --filter 'ancestor=pgvector/pgvector:pg16' --format '{{.Names}}' | head -n1)"
if [[ -z "$PG" ]]; then
  PG="$(docker ps --filter 'name=^/chat-services-postgres' --format '{{.Names}}' | head -n1)"
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

# 3b. Archive critical Docker volumes (NOT captured by pg_dump). We tar each
# volume read-only via a throwaway helper container so the archive is complete
# even if the consuming service is down. Resolve each configured suffix to a
# real volume name (tolerates the compose project prefix). Missing volumes are
# recorded so the section-6 coverage check can FAIL on them.
VOL_FILES=()
RESOLVED_VOLS=()
MISSING_VOLS=()
for suffix in $BACKUP_VOLUME_SUFFIXES; do
  vol="$(docker volume ls --format '{{.Name}}' | grep -E "(^|_)${suffix}\$" | head -n1)"
  if [[ -z "$vol" ]]; then
    log "AVISO: volume crítico com sufixo '${suffix}' não encontrado (docker volume ls)."
    MISSING_VOLS+=("$suffix")
    continue
  fi
  OUT="${BACKUP_DIR}/${vol}-${TS}.tar.gz"
  log "==> Archiving volume ${vol} → ${OUT}"
  # -v <vol>:/data:ro read-only source; write the tarball to STDOUT and land it
  # on the host so we never need a host bind-mount to be writable by the image.
  if docker run --rm -v "${vol}:/data:ro" "$BACKUP_HELPER_IMAGE" \
        tar czf - -C /data . > "$OUT" 2>/dev/null && [[ -s "$OUT" ]]; then
    VOL_FILES+=("$OUT")
    RESOLVED_VOLS+=("$vol")
  else
    log "ERRO: falha ao arquivar volume ${vol} (tar/helper image ${BACKUP_HELPER_IMAGE})."
    rm -f "$OUT" 2>/dev/null || true
    MISSING_VOLS+=("$suffix")
  fi
done

# 4. Local rotation (dumps + volume archives).
log "==> Limpando backups locais com mais de ${BACKUP_KEEP_DAYS} dias"
find "$BACKUP_DIR" -type f \( -name '*.sql.gz' -o -name '*.tar.gz' \) -mtime +"$BACKUP_KEEP_DAYS" -print -delete || true

# 5. Off-host copy (optional but strongly recommended — host loss = data loss).
if [[ -n "$BACKUP_RCLONE_REMOTE" ]]; then
  if command -v rclone >/dev/null 2>&1; then
    log "==> Copiando para ${BACKUP_RCLONE_REMOTE} via rclone (dumps + volume archives)"
    rclone copy "$BACKUP_DIR" "$BACKUP_RCLONE_REMOTE" \
      --include '*.sql.gz' --include '*.tar.gz' --max-age 25h
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

# 6b. Critical-volume coverage check (issue #61). A pg_dump that "succeeds" while
# the chatwoot-storage / dify-api-storage volumes went un-archived is the exact
# silent gap that produced this incident — so treat a missing/empty required
# volume archive as a hard failure that surfaces in the cron log.
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
  if [[ "$sz" -lt "$VOL_MIN_BYTES" ]]; then
    log "ERRO: arquivo de volume '${suffix}' suspeito (${sz} bytes < ${VOL_MIN_BYTES})."
    vol_missing=1
  fi
done
if [[ "$vol_missing" -ne 0 ]]; then
  log "==> FALHA: cobertura de backup de VOLUMES incompleta (${REQUIRED_VOL_SUFFIXES[*]})."
  exit 1
fi

# 7. Success marker (issue #121): write a timestamped marker ONLY on full
# success so health-check-all.sh / self-healing can detect a stale or failed
# backup unambiguously (a failing cron leaves this marker old). The .sql.gz
# mtime is the primary signal; this is the explicit belt-and-suspenders record.
MARKER="${BACKUP_DIR}/.last-success"
{ echo "$(date -Is)";
  echo "dbs=${#FILES[@]} critical_ok=${CRITICAL_DBS[*]} rclone=${BACKUP_RCLONE_REMOTE:-none}";
  echo "volumes=${#VOL_FILES[@]} archived=${RESOLVED_VOLS[*]:-none} required=${REQUIRED_VOL_SUFFIXES[*]}"; } > "$MARKER" || \
  log "AVISO: não consegui escrever marker de sucesso em $MARKER"

log "==> Backup concluído (${#FILES[@]} DBs, ${#VOL_FILES[@]} volumes; críticos OK: DBs=${CRITICAL_DBS[*]}, vols=${REQUIRED_VOL_SUFFIXES[*]})."
