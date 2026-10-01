#!/usr/bin/env bash
# W3c: synthetic DB only; never joins the production network or loads .env.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
image=$(sed -n 's/^    image: \(grafana\/grafana:.*\)$/\1/p' "$ROOT/deploy/docker-compose.nexaduo.yml")
[[ $image =~ ^grafana/grafana:13\.[^@]+@sha256:[a-f0-9]{64}$ ]]
old_image=grafana/grafana:11.6.16@sha256:d67af92050b8d93b393dc741864752a69c9da1ffa39c1bb9af49ad5d9e47d2c3
bridge_image=grafana/grafana:12.4.11@sha256:3ea272e5cab64a4a62240c682e2c62433b25614d956d44c299a10cb6994f6f2e
# Use the repository's PG16 variant (currently a floating pg16 tag, not a digest).
pg_image=$(sed -n 's/^    image: \(pgvector\/pgvector:.*\)$/\1/p' "$ROOT/deploy/docker-compose.shared.yml")
[[ -n $pg_image ]]
if [[ ${1:-} != --bounded ]]; then
  for img in "$pg_image" "$old_image" "$bridge_image" "$image"; do
    echo "Pulling $img before bounded test"
    docker pull "$img" >/dev/null
  done
  # 150s work + up to 18s cleanup, including on timeout/INT/TERM.
  exec timeout --signal=TERM --kill-after=20s 150s bash "$0" --bounded
fi
prefix="w3c-grafana-$(cat /proc/sys/kernel/random/uuid)"
old="$prefix-old"; bridge="$prefix-bridge"; new="$prefix-new"; pg="$prefix-pg"
network="$prefix-net"; volume="$prefix-data"; pg_volume="$prefix-db"
work=$(mktemp -d)
cleanup() {
  status=$?
  trap - EXIT
  trap '' INT TERM
  if (( status != 0 )); then
    echo 'FAIL: migration/provisioning test; last Grafana errors:' >&2
    for container in "$old" "$bridge" "$new"; do
      timeout 1s docker logs --tail 40 "$container" 2>&1 || true
    done
  fi
  timeout 7s docker rm -f "$old" "$bridge" "$new" "$pg" >/dev/null 2>&1 || status=1
  timeout 4s docker volume rm "$volume" "$pg_volume" >/dev/null 2>&1 || status=1
  timeout 3s docker network rm "$network" >/dev/null 2>&1 || status=1
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'echo "FAIL at script line $LINENO" >&2' ERR
trap 'exit 130' INT
trap 'exit 143' TERM
export POSTGRES_PASSWORD=$(openssl rand -hex 24)
export POSTGRES_USER=postgres
export GF_SECURITY_ADMIN_USER="synthetic-$(openssl rand -hex 8)"
export GF_SECURITY_ADMIN_PASSWORD=$(openssl rand -hex 24)
export GF_DATABASE_PASSWORD=$POSTGRES_PASSWORD
provisioning="$ROOT/observability/grafana/provisioning"
# Only modern built-in panels are provisioned; catch nested legacy Angular panels.
jq -e '[.. | objects | select(has("panels")) | .panels[]?.type |
  select(. == "graph" or . == "table-old" or . == "singlestat")] | length == 0' \
  "$provisioning"/dashboards/*.json >/dev/null
jq -sr 'map(.uid) | sort | .[]' "$provisioning"/dashboards/*.json > "$work/expected-dashboards"
sed -n 's/^    uid: //p' "$provisioning"/datasources/*.yml | sort > "$work/expected-datasources"
sed -n 's/^      - uid: //p' "$provisioning"/alerting/*.yml | sort > "$work/expected-alerts"
for kind in dashboards datasources alerts; do [[ -s $work/expected-$kind ]]; done
# Review: https://grafana.com/docs/grafana/latest/whatsnew/whats-new-in-v12-4/
# 12.4 can migrate small instances to unified storage automatically. Do not disable
# it here: this test must exercise defaults, including Postgres schema migrations.
# No custom plugins, Angular, editors_can_admin, permission provisioning or feature
# toggles. Plugin env filtering does not affect server-side datasource interpolation.
# 12.0 strict datasource UIDs already match. 12.1/12.2 need no local config edits.
# 12.3 folder permission inheritance changes require operator review for UI users.
# 12.4 NoData/Error pending periods change semantics; preserve our explicit states.
# W3c review: upgrade-guide/upgrade-v13.{0,1,2}/ and whats-new-in-v13-{0,1,2}.
# 13 migrates dashboards/folders to unified storage; never force legacy mode.
# Dynamic dashboards convert on open; retain schemaVersion 39 files and /d/<uid>.
# Existing datasource/provider/alert YAML remains supported (including annotations).
# No removed numeric-ID datasource/Alertmanager APIs or grafana-cli/server callers
# in scripts/, onboarding/, agents/; the tested legacy /api routes remain available.
# No custom React plugins, renderer, Git Sync or custom RBAC roles to migrate.
# GF_AUTH_GOOGLE_*, root_url, Postgres and cookie defaults remain compatible;
# gzip is now on by default. OAuth/tunnel and rendered links need live validation.
# 13.1/13.2 guides list no additional technical notes; runtime config.apps/panels
# removal in 13.2 affects custom plugins, not these built-in panel JSON documents.
docker network create "$network" >/dev/null
docker volume create "$volume" >/dev/null
docker volume create "$pg_volume" >/dev/null
docker run -d --name "$pg" --network "$network" --network-alias postgres \
  -e POSTGRES_PASSWORD -e POSTGRES_USER -e POSTGRES_DB=grafana \
  --mount "type=volume,src=$pg_volume,dst=/var/lib/postgresql/data" "$pg_image" >/dev/null
until docker exec "$pg" pg_isready -U postgres -d grafana >/dev/null 2>&1; do sleep 1; done
api() {
  curl -fsS --max-time 3 -u "$GF_SECURITY_ADMIN_USER:$GF_SECURITY_ADMIN_PASSWORD" "$url$1"
}
start() {
  docker run -d --name "$1" --network "$network" --publish 127.0.0.1::3000 \
    -e GF_SECURITY_ADMIN_USER -e GF_SECURITY_ADMIN_PASSWORD \
    -e POSTGRES_USER -e POSTGRES_PASSWORD -e GF_DATABASE_PASSWORD \
    -e GF_DATABASE_TYPE=postgres -e GF_DATABASE_HOST=postgres:5432 \
    -e GF_DATABASE_NAME=grafana -e GF_DATABASE_USER=postgres \
    --mount "type=bind,src=$provisioning,dst=/etc/grafana/provisioning,readonly" \
    --mount "type=volume,src=$volume,dst=/var/lib/grafana" "$2" >/dev/null
  url="http://$(docker port "$1" 3000/tcp)"
  until api /api/health 2>/dev/null | jq -e '.database == "ok"' >/dev/null; do sleep 1; done
  # Execute the exact compose healthcheck to prove wget and its flags still exist.
  docker exec "$1" wget -qO- -T 5 http://127.0.0.1:3000/api/health |
    jq -e '.database == "ok"' >/dev/null
}
snapshot() {
  local phase=$1 uid
  [[ $(docker exec "$pg" psql -U postgres -d grafana -Atc \
    'SELECT count(*) FROM migration_log WHERE NOT success') == 0 ]]
  if [[ $phase == v13 ]]; then
    # The migration marker, rather than healthy HTTP alone, proves unified storage.
    [[ $(docker exec "$pg" psql -U postgres -d grafana -Atc \
      "SELECT count(*) FROM unifiedstorage_migration_log
       WHERE migration_id = 'folders and dashboards migration' AND success") == 1 ]]
    [[ $(docker exec "$pg" psql -U postgres -d grafana -Atc \
      'SELECT count(*) FROM unifiedstorage_migration_log WHERE NOT success') == 0 ]]
  fi
  # Dashboard file provisioning may finish after the HTTP listener starts.
  until api '/api/search?type=dash-db&limit=1000' | jq -r '.[].uid' | sort > "$work/$phase-dashboards" &&
    cmp -s "$work/expected-dashboards" "$work/$phase-dashboards"; do sleep 1; done
  api /api/datasources > "$work/$phase-sources.json"
  jq -r '.[].uid' "$work/$phase-sources.json" | sort > "$work/$phase-datasources"
  api /api/v1/provisioning/alert-rules > "$work/$phase-rules.json"
  jq -e 'length > 0 and all(.[]; .provenance == "file")' "$work/$phase-rules.json" >/dev/null
  jq -r '.[].uid' "$work/$phase-rules.json" | sort > "$work/$phase-alerts"
  for kind in dashboards datasources alerts; do
    diff -u "$work/expected-$kind" "$work/$phase-$kind"
  done
  while read -r uid; do
    # Legacy provisioning metadata changes with unified storage;
    # require the actual dashboard to remain retrievable under its original UID.
    api "/api/dashboards/uid/$uid" | jq -e --arg uid "$uid" '.dashboard.uid == $uid and (.dashboard.panels | type == "array" and length > 0) and (.meta.url | startswith("/d/" + $uid + "/"))' >/dev/null
  done < "$work/expected-dashboards"
  # Rules must be registered with the evaluator on every version, not just stored.
  until api /api/prometheus/grafana/api/v1/rules | jq -r \
    '.data.groups[] | select(.name == "dify-token-usage") | .rules[].uid' | sort > "$work/$phase-runtime-alerts" &&
    cmp -s "$work/expected-alerts" "$work/$phase-runtime-alerts"; do sleep 1; done
  if [[ -n ${annotation_id:-} ]]; then
    api "/api/annotations?dashboardUID=$annotation_uid" | jq -e --argjson id "$annotation_id" \
      'any(.[]; .id == $id and .text == "synthetic upgrade annotation")' >/dev/null
  fi
}
logs_ok() {
  docker logs "$1" > "$work/log" 2>&1
  grep -qi 'migrations completed' "$work/log"
  if grep -Ei 'migration failed|failed to migrate|level=(error|fatal).*migra' "$work/log" ||
    grep -Ei 'level=(warn|error|fatal)' "$work/log" | grep -i angular; then
    return 1
  fi
}
echo "Starting isolated upgrade ($prefix)"
start "$old" "$old_image"
snapshot v11
logs_ok "$old"
annotation_uid=$(head -n 1 "$work/expected-dashboards")
annotation_id=$(jq -n --arg uid "$annotation_uid" \
  '{dashboardUID: $uid, time: (now * 1000 | floor), text: "synthetic upgrade annotation"}' |
  curl -fsS --max-time 3 -u "$GF_SECURITY_ADMIN_USER:$GF_SECURITY_ADMIN_PASSWORD" \
    -H 'Content-Type: application/json' --data-binary @- "$url/api/annotations" | jq -er '.id')
# Keep the same Postgres process/database and Grafana volume, no overlapping writers.
for phase in v12 v13; do
  if [[ $phase == v12 ]]; then
    docker stop -t 5 "$old" >/dev/null
    start "$bridge" "$bridge_image"
    logs_ok "$bridge"
  else
    docker stop -t 5 "$bridge" >/dev/null
    start "$new" "$image"
    logs_ok "$new"
  fi
  snapshot "$phase"
  # Preserve correlation config and alert annotations/queries across both hops.
  for version in v11 "$phase"; do
    jq -S 'sort_by(.uid) | map({uid, type, url, jsonData})' "$work/$version-sources.json" > "$work/$version-links"
    jq -S 'sort_by(.uid) | map({uid, condition, data, annotations, noDataState, execErrState})' \
      "$work/$version-rules.json" > "$work/$version-rule-config"
  done
  diff -u "$work/v11-links" "$work/$phase-links"
  diff -u "$work/v11-rule-config" "$work/$phase-rule-config"
done
echo "PASS: Grafana 11 -> 12 -> 13 Postgres migrations, healthcheck, panels, UIDs, annotations, rules and correlation config (${SECONDS}s)"
