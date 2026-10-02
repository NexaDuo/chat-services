#!/usr/bin/env bash
# Rehearse a PostgreSQL MAJOR upgrade by dump/restore, on a COPY of production
# data. Restores the newest dump of every database into two throwaway servers:
# the previous major ($PG_OLD_IMAGE) and the image pinned in
# deploy/docker-compose.shared.yml, both initialised with the versioned
# 01-init.sql exactly like a fresh production volume. Their manifests
# (scripts/pg-manifest.sh: exact row count of every table, sequences, indexes,
# constraints, extensions) must be identical.
#
# Nothing here touches the live stack: the containers have no network, no
# volume outside the container, and are removed on exit. Dumps contain
# production data: nothing is printed but counts.
#
#   scripts/rehearse-postgres-major.sh
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${DUMPS_DIR:=$HOME/nexaduo-local/dumps}"
: "${PG_OLD_IMAGE:=pgvector/pgvector:0.8.6-pg16@sha256:ccc6e83d6e35e931dc7c5def2022729d5a6c370318d099181995567ff1fb4d6b}"
log() { echo "[rehearsal] $*"; }
die() { echo "[rehearsal] FAIL: $*" >&2; exit 1; }

new_image=$(docker compose --env-file /dev/null -f "$ROOT/deploy/docker-compose.shared.yml" \
  config --format json 2>/dev/null | jq -er '.services.postgres.image')
proj="pg-rehearsal-$(openssl rand -hex 4)"
work=""
cleanup() {
  local status=$?
  trap - EXIT
  docker rm -fv "$proj-old" "$proj-new" >/dev/null 2>&1 || true
  [[ -z "$work" ]] || rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
work=$(mktemp -d)

# The newest dump of each database, as scripts/backup-host.sh names them.
declare -A dumps=()
shopt -s nullglob
for f in "$DUMPS_DIR"/*-20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9].sql.gz; do
  db=$(basename "$f" | sed -E 's/-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}\.sql\.gz$//')
  [[ -z "${dumps[$db]:-}" || "$f" > "${dumps[$db]}" ]] && dumps[$db]=$f
done
shopt -u nullglob
(( ${#dumps[@]} > 0 )) || die "no dumps in $DUMPS_DIR"
for db in "${!dumps[@]}"; do gzip -t "${dumps[$db]}" || die "corrupt: ${dumps[$db]}"; done

start() { # suffix image
  # The cluster lives in RAM, on the image's own data path: a copy of
  # production data must not outlive the container, even after a SIGKILL.
  local datapath
  datapath=$(docker image inspect "$2" --format '{{range $k, $_ := .Config.Volumes}}{{$k}}{{end}}')
  [[ "$datapath" == /var/lib/postgresql* ]] || die "unexpected data path in $2: $datapath"
  docker run -d --name "$proj-$1" --network none --tmpfs "$datapath" -e POSTGRES_PASSWORD="$(openssl rand -hex 24)" \
    -v "$ROOT/infrastructure/postgres/01-init.sql:/docker-entrypoint-initdb.d/01-init.sql:ro" \
    "$2" >/dev/null
  local n=0
  # TCP, not the socket: the image's init phase runs a socket-only server first.
  until docker exec "$proj-$1" pg_isready -q -h 127.0.0.1 -U postgres; do
    n=$((n + 1)); (( n < 90 )) || die "$1 server not ready"
    sleep 1
  done
}
restore() { # suffix
  local db dbs
  mapfile -t dbs < <(printf '%s\n' "${!dumps[@]}" | sort)
  for db in "${dbs[@]}"; do
    # Database names come from dump file names: accept only plain identifiers.
    [[ "$db" =~ ^[a-z_][a-z0-9_]*$ ]] || die "unexpected database name in $DUMPS_DIR: $db"
    docker exec "$proj-$1" psql -U postgres -Atc "select 1 from pg_database where datname = '$db'" | grep -q 1 \
      || docker exec "$proj-$1" psql -U postgres -Atc "create database \"$db\"" >/dev/null
    # Only the first ERROR line is shown: later lines (CONTEXT of a failed COPY)
    # can quote row data.
    gzip -dc "${dumps[$db]}" | docker exec -i "$proj-$1" psql -v ON_ERROR_STOP=1 -U postgres -d "$db" \
      >/dev/null 2>"$work/restore-$1-$db.err" \
      || die "restore of $db into $1 failed: $(grep -m1 -E '^(psql:.*)?ERROR:' "$work/restore-$1-$db.err" | cut -c1-160)"
  done
}

log "dumps: $(for db in $(printf '%s\n' "${!dumps[@]}" | sort); do printf '%s ' "$(basename "${dumps[$db]}")"; done)"
start old "$PG_OLD_IMAGE"
start new "$new_image"
old_version=$(docker exec "$proj-old" psql -U postgres -Atc 'show server_version')
new_version=$(docker exec "$proj-new" psql -U postgres -Atc 'show server_version')
log "old server $old_version, new server $new_version"
[[ "${old_version%%.*}" != "${new_version%%.*}" ]] || log "note: same major on both sides"

t=$SECONDS; restore old; log "restored into the old server in $((SECONDS - t))s"
t=$SECONDS; restore new; log "restored into the new server in $((SECONDS - t))s"

"$ROOT/scripts/pg-manifest.sh" "$proj-old" > "$work/old.txt"
"$ROOT/scripts/pg-manifest.sh" "$proj-new" > "$work/new.txt"
[[ "$(grep -c '^table|' "$work/new.txt")" -gt 0 ]] || die "empty manifest from the new server"
# Contrib extension versions follow the server major; everything else must match.
if ! diff <(grep -v '^extversion|' "$work/old.txt") <(grep -v '^extversion|' "$work/new.txt") > "$work/manifest.diff"; then
  # Table names and counts only: no row content.
  head -n 20 "$work/manifest.diff" >&2
  die "manifests differ between $old_version and $new_version"
fi
log "manifests identical: $(grep -c '^== ' "$work/new.txt") databases, $(grep -c '^table|' "$work/new.txt") tables, $(awk -F'|' '$1=="table"{n+=$3} END{print n}' "$work/new.txt") rows, $(grep -c '^sequence|' "$work/new.txt") sequences"
log "extension versions on the new server: $(grep '^extversion|' "$work/new.txt" | cut -d'|' -f2,3 | sort -u | tr '|' ':' | tr '\n' ' ')"
changed=$(diff <(grep '^extversion|' "$work/old.txt" | sort -u) <(grep '^extversion|' "$work/new.txt" | sort -u) | grep -c '^>' || true)
log "extension versions that changed with the major: $changed"
[[ "$(grep '^invalid_indexes|' "$work/new.txt" | cut -d'|' -f2 | sort -u)" == 0 ]] || die "invalid indexes on the new server"
vec=$(docker exec "$proj-new" psql -U postgres -d dify -Atc "select extversion from pg_extension where extname = 'vector'")
[[ -n "$vec" ]] || die "pgvector missing in dify on the new server"
docker exec "$proj-new" psql -U postgres -d dify -v ON_ERROR_STOP=1 -Atc "select '[1,2,3]'::vector <-> '[1,2,4]'::vector" >/dev/null \
  || die "pgvector operator not working on the new server"
log "PASS in ${SECONDS}s"
