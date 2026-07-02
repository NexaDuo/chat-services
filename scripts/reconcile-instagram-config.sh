#!/usr/bin/env bash
# =============================================================================
# reconcile-instagram-config.sh — reconcile Chatwoot's Instagram Login channel
# credentials (installation_configs) from the versioned host `.env` values.
#
# WHY (issue #114 / memory chatwoot-installation-configs-mask-env):
#   Chatwoot resolves INSTAGRAM_APP_ID / INSTAGRAM_APP_SECRET / INSTAGRAM_VERIFY_TOKEN
#   via GlobalConfigService, which reads the `installation_configs` DB rows BEFORE
#   ENV. Today those three rows live ONLY in the database (drift) — a from-scratch
#   rebuild would NOT reapply them, violating AGENTS.md reproducibility. This
#   script makes the host `.env` the source of truth and idempotently UPSERTs the
#   three rows into the running Chatwoot, so a rebuild reproduces them.
#
#   NOTE (#114): INSTAGRAM_APP_ID is the tenant's Instagram App ID
#   (Duda: 1042111571516215) — NOT the Facebook App ID 2765038230562952, which
#   fails the Instagram Login OAuth with "Invalid platform app". To repoint the
#   channel, change the three .env values and re-run this script.
#
# HOW:
#   Uses Chatwoot's own InstallationConfig model via `rails runner` so the value
#   is serialized exactly as Chatwoot expects (ActiveSupport::HashWithIndifferentAccess
#   { value: <string> }) and GlobalConfig.clear_cache runs on commit. It never
#   touches Postgres directly and never recreates/drops anything — pure UPDATE/UPSERT
#   of three rows. SACRED Postgres is untouched (AGENTS.md Operational Non-Negotiables).
#
# IDEMPOTENT: if a row already holds the target value it is left as-is (no write,
#   no cache churn). Re-running with the same .env is a no-op.
#
# USAGE:
#   scripts/reconcile-instagram-config.sh            # apply from ./.env
#   scripts/reconcile-instagram-config.sh --dry-run  # show current vs target, no writes
#   ENV_FILE=/path/.env CHATWOOT_CONTAINER=... scripts/reconcile-instagram-config.sh
#
# NOTE: After applying, restart/refresh Chatwoot workers so long-lived processes
#   pick up the new GlobalConfig (the model clears the cache, but re-authing the
#   channel via the Chatwoot UI as the IG account is still required to mint a new
#   token against the new app — see #114). This script does NOT re-OAuth.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
CHATWOOT_CONTAINER="${CHATWOOT_CONTAINER:-nexaduo-chatwoot-rails-1}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

log()  { echo -e "\033[0;32m[reconcile-ig]\033[0m $*"; }
warn() { echo -e "\033[0;33m[reconcile-ig]\033[0m $*" >&2; }
die()  { echo -e "\033[0;31m[reconcile-ig] ERROR:\033[0m $*" >&2; exit 1; }

# --- Load the three keys from the host .env (source of truth) ---------------
[[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE — the versioned source for the IG creds (see .env.production.example)"

# tolerant of no-match (grep would exit 1 and, under set -e/pipefail, abort)
read_env() { { grep -E "^$1=" "$ENV_FILE" || true; } | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"; }

APP_ID="$(read_env INSTAGRAM_APP_ID)"
APP_SECRET="$(read_env INSTAGRAM_APP_SECRET)"
VERIFY_TOKEN="$(read_env INSTAGRAM_VERIFY_TOKEN)"

missing=()
[[ -n "$APP_ID"       ]] || missing+=(INSTAGRAM_APP_ID)
[[ -n "$APP_SECRET"   ]] || missing+=(INSTAGRAM_APP_SECRET)
[[ -n "$VERIFY_TOKEN" ]] || missing+=(INSTAGRAM_VERIFY_TOKEN)
if [[ ${#missing[@]} -gt 0 ]]; then
  die "these keys are empty/missing in $ENV_FILE: ${missing[*]}
       Add them (INSTAGRAM_APP_ID=1042111571516215 + Instagram app secret + verify token) before reconciling — see #114."
fi

docker inspect "$CHATWOOT_CONTAINER" >/dev/null 2>&1 || die "container $CHATWOOT_CONTAINER not found (set CHATWOOT_CONTAINER=...)"

# Mask secrets in logs.
mask() { local v="$1"; [[ ${#v} -le 8 ]] && printf '****' || printf '%s…%s' "${v:0:4}" "${v: -2}"; }
log "source $ENV_FILE  →  container $CHATWOOT_CONTAINER"
log "  INSTAGRAM_APP_ID=$APP_ID"
log "  INSTAGRAM_APP_SECRET=$(mask "$APP_SECRET")"
log "  INSTAGRAM_VERIFY_TOKEN=$(mask "$VERIFY_TOKEN")"

# --- Reconcile via Chatwoot's own model (idempotent) -------------------------
# The Ruby below is fed on stdin to `rails runner -` and reads the three target
# values from ENV inside the container so no secrets land in the process args /
# shell history. For each key: skip if already equal, otherwise UPSERT and report.
RUBY_SCRIPT='
targets = {
  "INSTAGRAM_APP_ID"       => ENV.fetch("IG_APP_ID"),
  "INSTAGRAM_APP_SECRET"   => ENV.fetch("IG_APP_SECRET"),
  "INSTAGRAM_VERIFY_TOKEN" => ENV.fetch("IG_VERIFY_TOKEN")
}
dry = ENV["IG_DRY_RUN"] == "1"
changed = 0
targets.each do |name, want|
  cfg = InstallationConfig.find_or_initialize_by(name: name)
  have = cfg.persisted? ? cfg.value : nil
  masked = %w[INSTAGRAM_APP_SECRET INSTAGRAM_VERIFY_TOKEN].include?(name)
  show = ->(v) { v.nil? ? "(unset)" : (masked ? "#{v.to_s[0,4]}…(len #{v.to_s.length})" : v) }
  if have.to_s == want.to_s
    puts "  [ok]      #{name} already = #{show.call(have)}"
    next
  end
  puts "  [#{dry ? "would" : "change"}]  #{name}: #{show.call(have)} -> #{show.call(want)}"
  next if dry
  cfg.value = want
  cfg.save!
  changed += 1
end
unless dry
  GlobalConfig.clear_cache
  puts "  cache cleared; #{changed} row(s) written"
end
puts dry ? "DRY-RUN: no writes" : "reconcile complete"
'

log "$([[ $DRY_RUN -eq 1 ]] && echo "DRY-RUN — no writes" || echo "applying")"
docker exec -i \
  -e IG_APP_ID="$APP_ID" \
  -e IG_APP_SECRET="$APP_SECRET" \
  -e IG_VERIFY_TOKEN="$VERIFY_TOKEN" \
  -e IG_DRY_RUN="$DRY_RUN" \
  "$CHATWOOT_CONTAINER" bundle exec rails runner - <<<"$RUBY_SCRIPT"

if [[ $DRY_RUN -eq 0 ]]; then
  warn "Reminder: re-OAuth the Instagram channel in the Chatwoot UI (log in as the"
  warn "IG account) to mint a fresh token against the new app — see #114 next steps."
fi
