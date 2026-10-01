#!/usr/bin/env bash
# W3b: synthetic DB only; never joins the production network or loads .env.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
image=$(sed -n 's/^    image: \(grafana\/grafana:.*\)$/\1/p' "$ROOT/deploy/docker-compose.nexaduo.yml")
[[ $image =~ ^grafana/grafana:12\.[^@]+@sha256:[a-f0-9]{64}$ ]]
old_image=grafana/grafana:11.6.16@sha256:d67af92050b8d93b393dc741864752a69c9da1ffa39c1bb9af49ad5d9e47d2c3
# Use the repository's PG16 variant (currently a floating pg16 tag, not a digest).
pg_image=$(sed -n 's/^    image: \(pgvector\/pgvector:.*\)$/\1/p' "$ROOT/deploy/docker-compose.shared.yml")
[[ -n $pg_image ]]
if [[ ${1:-} != --bounded ]]; then
  for img in "$pg_image" "$old_image" "$image"; do
    echo "Pulling $img before bounded test"
    docker pull "$img" >/dev/null
  done
  # 125s work + up to 17s cleanup, including on timeout/INT/TERM.
  exec timeout --signal=TERM --kill-after=20s 125s bash "$0" --bounded
fi
prefix="w3b-grafana-$(cat /proc/sys/kernel/random/uuid)"
old="$prefix-old"; new="$prefix-new"; pg="$prefix-pg"
network="$prefix-net"; volume="$prefix-data"; pg_volume="$prefix-db"
work=$(mktemp -d)
cleanup() {
  status=$?
  trap - EXIT
  trap '' INT TERM
  if (( status != 0 )); then
    echo 'FAIL: migration/provisioning test; last Grafana errors:' >&2
    for container in "$old" "$new"; do
      timeout 1s docker logs --tail 40 "$container" 2>&1 || true
    done
  fi
  timeout 7s docker rm -f "$old" "$new" "$pg" >/dev/null 2>&1 || status=1
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
    # Legacy provisioning metadata changes with unified storage in 12.4;
    # require the actual dashboard to remain retrievable under its original UID.
    api "/api/dashboards/uid/$uid" | jq -e --arg uid "$uid" '.dashboard.uid == $uid' >/dev/null
  done < "$work/expected-dashboards"
}
logs_ok() {
  docker logs "$1" > "$work/log" 2>&1
  grep -qi 'migrations completed' "$work/log"
  if grep -Ei 'migration failed|failed to migrate' "$work/log" ||
    grep -Ei 'level=(warn|error|fatal)' "$work/log" | grep -i angular; then
    return 1
  fi
}
echo "Starting isolated upgrade ($prefix)"
start "$old" "$old_image"
snapshot before
logs_ok "$old"
# Keep the same Postgres process/database and Grafana volume, with no overlapping writers.
docker stop -t 5 "$old" >/dev/null
start "$new" "$image"
snapshot after
logs_ok "$new"
# Preserve correlation configuration (derivedFields/tracesToLogsV2) and all other
# datasource settings, excluding DB IDs which are not part of the UID contract.
for phase in before after; do
  jq -S 'sort_by(.uid) | map({uid, type, url, jsonData})' "$work/$phase-sources.json" > "$work/$phase-links"
done
diff -u "$work/before-links" "$work/after-links"
# The runtime health script uses this different API, with UIDs nested in rules.
api /api/prometheus/grafana/api/v1/rules | jq -r \
  '.data.groups[] | select(.name == "dify-token-usage") | .rules[].uid' | sort > "$work/runtime-alerts"
diff -u "$work/expected-alerts" "$work/runtime-alerts"
for kind in dashboards datasources alerts; do diff -u "$work/before-$kind" "$work/after-$kind"; done
echo "PASS: Grafana 11 -> 12 Postgres migrations, healthcheck, provisioned UIDs and Angular checks (${SECONDS}s)"
