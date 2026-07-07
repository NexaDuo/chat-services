#!/usr/bin/env bash
# =============================================================================
# uptime-probe.sh — INDEPENDENT external uptime probe for the public tunnel URLs
# (issue #138).
#
# WHY: on 2026-07-07 the WSL host rebooted and the stack stayed down for ~6h.
# cloudflared kept the tunnel registered so the domains still "answered" at the
# edge, and there was NO independent watcher, so nobody was alerted — the outage
# was found by a human stumbling on it. An uptime check that runs ON the same
# host cannot alert when the host itself is down, so the real watchdog is the
# scheduled GitHub Actions workflow `.github/workflows/uptime-probe.yml`, which
# runs this script OFF-host and alerts on failure. This script is also runnable
# on-host for spot checks.
#
# ALERTING (where the alert goes):
#   1. UPTIME_ALERT_WEBHOOK  — if set, a JSON {"text": "..."} POST is sent to it
#      (Slack / Discord / ntfy / Mattermost incoming-webhook compatible). In the
#      GitHub Actions run this is the repo secret `UPTIME_ALERT_WEBHOOK`.
#   2. The workflow ALSO opens/updates a GitHub issue (label `uptime-down`) on a
#      non-zero exit, so there is a durable alert even without a webhook.
#
# EXIT: 0 = every endpoint healthy. Non-zero = at least one endpoint DOWN (the
# workflow keys its GitHub-issue alert off this exit code).
# =============================================================================
set -uo pipefail

# "name|url|comma-separated-expected-codes", one per line. Defaults to the public
# production tunnel URLs. Override via UPTIME_PROBES (e.g. to point at a known-down
# endpoint when demonstrating the alert path).
# Expected codes are deliberately GENEROUS (2xx/3xx + benign auth codes): the goal
# is to detect a real outage (5xx / connection refused / timeout => code 000), not
# to page on a harmless redirect change. `/health` and the Dify setup endpoint are
# the exceptions where a specific 200 is meaningful.
DEFAULT_PROBES="chatwoot|https://chat.nexaduo.com/|200,301,302,307,308
dify-web|https://dify.nexaduo.com/|200,301,302,307,308
dify-api|https://dify.nexaduo.com/console/api/setup|200
evolution|https://evolution.nexaduo.com/|200,301,302,307,308,401,403,404
middleware|https://middleware.nexaduo.com/health|200
grafana|https://grafana.nexaduo.com/|200,301,302,307,308"

PROBES="${UPTIME_PROBES:-$DEFAULT_PROBES}"
RETRIES="${UPTIME_RETRIES:-3}"
TIMEOUT="${UPTIME_TIMEOUT:-15}"
WEBHOOK="${UPTIME_ALERT_WEBHOOK:-}"

failures=()
total=0
while IFS='|' read -r name url codes; do
  name="$(echo "$name" | tr -d '[:space:]')"
  [[ -z "$name" ]] && continue
  total=$((total + 1))
  code="000"
  for _ in $(seq 1 "$RETRIES"); do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$url" 2>/dev/null || echo 000)"
    case ",$codes," in *",$code,"*) break ;; esac
    sleep 3
  done
  case ",$codes," in
    *",$code,"*) echo "OK   $name -> $code ($url)" ;;
    *) echo "DOWN $name -> $code (expected one of $codes) ($url)" >&2
       failures+=("$name ($url) returned $code, expected one of [$codes]") ;;
  esac
done <<< "$PROBES"

if (( ${#failures[@]} == 0 )); then
  echo "uptime-probe: all ${total} endpoint(s) healthy"
  exit 0
fi

msg="UPTIME ALERT (issue #138 uptime-probe): ${#failures[@]}/${total} endpoint(s) DOWN at $(ts 2>/dev/null || date -u +'%Y-%m-%dT%H:%M:%SZ'):"
for f in "${failures[@]}"; do
  msg+=$'\n'"- ${f}"
done
echo "$msg" >&2

# Alert channel 1: generic JSON webhook.
if [[ -n "$WEBHOOK" ]]; then
  payload="$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps({"text": sys.stdin.read()}))' 2>/dev/null || printf '{"text":"uptime alert (see logs)"}')"
  if curl -sS -X POST -H 'Content-Type: application/json' --max-time 15 -d "$payload" "$WEBHOOK" >/dev/null 2>&1; then
    echo "uptime-probe: alert POSTed to UPTIME_ALERT_WEBHOOK"
  else
    echo "uptime-probe: WARN failed to POST alert to UPTIME_ALERT_WEBHOOK" >&2
  fi
else
  echo "uptime-probe: UPTIME_ALERT_WEBHOOK not set — no webhook alert (the CI workflow still opens a GitHub issue on this non-zero exit)" >&2
fi

exit 1
