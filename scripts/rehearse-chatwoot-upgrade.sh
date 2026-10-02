#!/usr/bin/env bash
# Rehearse a Chatwoot upgrade on a COPY of production data.
#
# Restores the newest `chatwoot` dump into a throwaway Postgres, copies the
# storage archive into a throwaway volume, and runs the Chatwoot image pinned
# in deploy/docker-compose.chatwoot.yml against them. Nothing here writes to
# the live stack, and the rehearsal network is INTERNAL (no egress): the copy
# carries real channel credentials, so nothing in it may reach Meta, WhatsApp
# or the real middleware.
#
#   scripts/rehearse-chatwoot-upgrade.sh          # migrate + boot + checks
#   scripts/rehearse-chatwoot-upgrade.sh --keep   # leave everything up
#
# Requires: Docker/Compose, jq and openssl; the root .env; dumps from
# scripts/backup-host.sh. Logs go to $REHEARSAL_LOG_DIR (mode 700), never to
# stdout: Rails can print credentials.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${ENV_FILE:=$ROOT/.env}"
: "${DUMPS_DIR:=$HOME/nexaduo-local/dumps}"
: "${PROD_PROJECT:=chat-services}"
: "${REHEARSAL_LOG_DIR:=$HOME/nexaduo-local/rehearsal}"
keep=0
for arg in "$@"; do
  case "$arg" in
    --keep) keep=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { echo "[rehearsal] $*"; }
die() { echo "[rehearsal] FAIL: $*" >&2; exit 1; }
newest() { { ls -1 "$DUMPS_DIR"/$1 2>/dev/null || true; } | sort | tail -n 1; }

[[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE"
dump=$(newest 'chatwoot-2*.sql.gz')
storage_tar=$(newest "${PROD_PROJECT}_chatwoot-storage-2*.tar.gz")
[[ -n "$dump" && -n "$storage_tar" ]] || die "need a chatwoot dump and a chatwoot-storage archive in $DUMPS_DIR"
for f in "$dump" "$storage_tar"; do gzip -t "$f" || die "corrupt: $f"; done

proj="chatwoot-rehearsal-$(openssl rand -hex 4)"
work="" logdir=""
cleanup() {
  local status=$?
  trap - EXIT
  if (( keep )); then
    log "kept: project $proj (network, volumes, containers); logs in $logdir"
    log "the volumes hold a copy of PRODUCTION data: remove them when done"
    log "remove with: docker ps -aq --filter name=$proj | xargs -r docker rm -fv; docker volume ls -q | grep ^$proj | xargs -r docker volume rm; docker network rm $proj"
  else
    dc down --timeout 5 >/dev/null 2>&1 || true
    docker rm -fv "$proj-postgres" "$proj-redis" "$proj-receiver" >/dev/null 2>&1 || true
    docker volume rm "${proj}_chatwoot-storage" "${proj}_pg" >/dev/null 2>&1 || true
    docker network rm "$proj" >/dev/null 2>&1 || true
  fi
  [[ -z "$work" ]] || rm -rf "$work"
  (( status == 0 )) || log "failed; service logs (may contain secrets) are in $logdir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

work=$(mktemp -d)
mkdir -p -m 700 "$REHEARSAL_LOG_DIR"
logdir="$REHEARSAL_LOG_DIR/$proj"; mkdir -m 700 "$logdir"
export POSTGRES_PASSWORD REDIS_PASSWORD NEXADUO_CONF_PATH="$ROOT"
POSTGRES_PASSWORD="$(openssl rand -hex 24)"; REDIS_PASSWORD="$(openssl rand -hex 24)"

helper=$(sed -n 's/^: "\${BACKUP_HELPER_IMAGE:=\([^}]*\)}".*/\1/p' "$ROOT/scripts/backup-host.sh")
shared=$(docker compose --env-file /dev/null -f "$ROOT/deploy/docker-compose.shared.yml" \
  config --format json 2>/dev/null)
pg_image=$(jq -er '.services.postgres.image' <<<"$shared")
redis_image=$(jq -er '.services.redis.image' <<<"$shared")

# Labels are reset so the live Traefik and autoheal ignore these containers,
# and the log driver is off so Alloy ships nothing to Loki. `compose up` is
# attached instead and written to $logdir.
{
  echo "services:"
  for svc in chatwoot-init chatwoot-rails chatwoot-sidekiq; do
    printf '  %s:\n    labels: !reset []\n    ports: !reset []\n    restart: "no"\n    logging: !override\n      driver: none\n' "$svc"
  done
  cat <<YAML
volumes:
  chatwoot-storage:
    external: true
    name: ${proj}_chatwoot-storage
networks:
  chat-network:
    external: true
    name: ${proj}
YAML
} > "$work/override.yml"
dc() {
  (cd "$ROOT" && docker compose --env-file "$ENV_FILE" -p "$proj" \
    -f deploy/docker-compose.chatwoot.yml -f "$work/override.yml" "$@")
}
cw_image=$(dc config --format json 2>/dev/null | jq -er '.services["chatwoot-rails"].image')

psql_db() { docker exec -i "$proj-postgres" psql -v ON_ERROR_STOP=1 -U postgres -d chatwoot -At "$@"; }
wait_for() { # description, seconds, command...
  local what=$1 limit=$2 start=$SECONDS; shift 2
  until "$@" >/dev/null 2>&1; do
    (( SECONDS - start < limit )) || die "$what not ready after ${limit}s"
    sleep 2
  done
}

log "project $proj; dump: $(basename "$dump"); storage: $(basename "$storage_tar"); image: ${cw_image%%@*}"
docker network create --internal "$proj" >/dev/null
for v in chatwoot-storage pg; do docker volume create "${proj}_$v" >/dev/null; done
docker run --rm -i --network none -v "${proj}_chatwoot-storage:/dst" "$helper" tar xzf - -C /dst < "$storage_tar"

docker run -d --name "$proj-postgres" --network "$proj" --network-alias postgres \
  --log-driver none -e POSTGRES_PASSWORD -v "${proj}_pg:/var/lib/postgresql/data" "$pg_image" >/dev/null
docker run -d --name "$proj-redis" --network "$proj" --network-alias redis \
  --log-driver none -e REDIS_PASSWORD "$redis_image" \
  sh -c 'exec redis-server --requirepass "$REDIS_PASSWORD"' >/dev/null
# TCP, not the socket: the image's init phase runs a socket-only server first.
wait_for Postgres 60 docker exec "$proj-postgres" pg_isready -q -h 127.0.0.1 -U postgres
# The broker version the clients are exercised against (from the compose pin).
log "redis $(docker exec -e REDISCLI_AUTH="$REDIS_PASSWORD" "$proj-redis" redis-cli --no-auth-warning info server | tr -d '\r' | sed -n 's/^redis_version://p'), postgres $(docker exec "$proj-postgres" psql -U postgres -Atc 'show server_version')"
docker exec "$proj-postgres" psql -U postgres -Atc 'create database chatwoot' >/dev/null
gzip -dc "$dump" | psql_db >/dev/null 2>"$logdir/restore.err" || die "chatwoot restore failed"

# Stand-in for the middleware: the Agent Bot's outgoing_url in the copy points
# at http://middleware:4000. It records method and path only (the query string
# carries the webhook token), tags the negative-control probe, and answers 200.
cat > "$work/receiver.rb" <<'RUBY'
require 'socket'
server = TCPServer.new('0.0.0.0', 4000)
loop do
  client = server.accept
  request = client.gets.to_s
  length = 0
  while (line = client.gets) && line != "\r\n"
    length = line.split(':', 2)[1].to_i if line.downcase.start_with?('content-length:')
  end
  body = length.positive? ? client.read(length).to_s : ''
  method, target = request.split
  tag = body.include?('negative control') ? ' negative' : ''
  File.open('/tmp/hits', 'a') { |f| f.puts "#{method} #{target.to_s.split('?').first}#{tag}" }
  client.write "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
  client.close
end
RUBY
docker run -d --name "$proj-receiver" --network "$proj" --network-alias middleware \
  --log-driver none -v "$work/receiver.rb:/receiver.rb:ro" --entrypoint ruby "$cw_image" /receiver.rb >/dev/null

# Row counts that a version upgrade must not change.
tables=(accounts users account_users inboxes contacts contact_inboxes conversations messages
        attachments agent_bots agent_bot_inboxes webhooks channel_whatsapp channel_instagram
        active_storage_blobs active_storage_attachments)
snapshot() {
  local t
  for t in "${tables[@]}"; do
    printf '%s=%s\n' "$t" "$(psql_db -c "select count(*) from \"$t\"")"
  done
}
schema_version() { psql_db -c 'select max(version) from schema_migrations'; }
before_rev=$(schema_version)
snapshot > "$work/before.txt"

log "migrating (chatwoot-init: db:prepare, same command as the cutover)"
start=$SECONDS
dc run --rm --no-deps chatwoot-init > "$logdir/migration.log" 2>&1 || die "migration failed (see $logdir/migration.log)"
after_rev=$(schema_version)
log "migrated in $((SECONDS - start))s: schema $before_rev -> $after_rev"

dc up --no-deps chatwoot-rails chatwoot-sidekiq > "$logdir/app.log" 2>&1 &
rails_exec() { dc exec -T chatwoot-rails "$@"; }
wait_for "chatwoot-rails" 300 rails_exec wget -qO /dev/null http://127.0.0.1:3000/
wait_for "chatwoot-sidekiq" 240 dc exec -T chatwoot-sidekiq sh -c 'cd /app && bundle exec sidekiqmon processes 2>&1 | grep -qF "$HOSTNAME"'
log "rails and sidekiq are up"

[[ "$(schema_version)" == "$after_rev" ]] || die "schema version moved on boot"
snapshot > "$work/after.txt"
diff -u "$work/before.txt" "$work/after.txt" > "$logdir/counts.diff" || die "row counts changed (see $logdir/counts.diff)"
log "row counts preserved: $(tr '\n' ' ' < "$work/after.txt")"

# The image must be self-consistent: the API reports the pinned version and
# the login page references a frontend asset the same container serves. (This
# does not detect a stale /app/public volume; compose no longer mounts one.)
version=${cw_image#*:v}; version=${version%%-*}
rails_exec sh -ec '
  api=$(wget -qO- http://127.0.0.1:3000/api)
  echo "$api" | grep -q "\"version\":\"$1\"" || { echo "unexpected /api version"; exit 1; }
  asset=$(wget -qO- http://127.0.0.1:3000/app/login | grep -o "/vite/assets/[A-Za-z0-9_.-]*\.js" | head -n 1)
  [ -n "$asset" ] || { echo "no vite asset referenced"; exit 1; }
  wget -qO /dev/null "http://127.0.0.1:3000$asset" || { echo "referenced asset not served"; exit 1; }
  # Open Graph tags (issue #273) are only added for the public host, so ask as it.
  host=${FRONTEND_URL#*://}; host=${host%%/*}
  og=$(wget -qO- --header "Host: $host" http://127.0.0.1:3000/app/login | grep -c "<meta property=\"og:image\" content=\"http") || true
  [ "$og" = 1 ] || { echo "expected one og:image tag for $host, found $og"; exit 1; }
  wget -qO /dev/null http://127.0.0.1:3000/og-images/default.png || { echo "og-images/default.png not served"; exit 1; }
' sh "$version" > "$logdir/web.log" 2>&1 || die "web checks failed (see $logdir/web.log)"
log "web: /api reports $version, the referenced frontend asset is served, og:image is emitted and served"

# Application-level checks inside Rails, after the count comparison because
# the bot probe creates a contact, a conversation and a message in the copy.
rails_exec bundle exec rails runner - > "$logdir/runner.log" 2>&1 <<'RUBY' || die "rails checks failed (see $logdir/runner.log)"
require 'logger'
Rails.logger = Logger.new(File::NULL)
ActiveRecord::Base.logger = nil
ActiveJob::Base.logger = Logger.new(File::NULL)
begin
  raise 'pending migrations' if ActiveRecord::Base.connection_pool.migration_context.needs_migration?
  raise 'assume_ssl initializer not applied' unless Rails.application.config.assume_ssl
  raise 'private network fetch not allowed' unless SafeFetch.allow_private_network?

  # Every stored upload must still be readable from the copied volume.
  blobs = ActiveStorage::Blob.where(id: ActiveStorage::Attachment.select(:blob_id))
  raise 'no attached blob in the copy: storage check would prove nothing' if blobs.empty?
  unreadable = blobs.reject { |blob| blob.service.exist?(blob.key) }
  raise "#{unreadable.size} of #{blobs.size} attached blobs missing from storage" if unreadable.any?
  sample = blobs.order(:byte_size).first
  raise 'blob download size mismatch' if sample && sample.download.bytesize != sample.byte_size

  # Agent Bot: a real incoming message in a bot inbox must stay pending and
  # reach the bot's own outgoing_url (private address) with a 2xx.
  link = AgentBotInbox.where(status: :active).first or raise 'no active Agent Bot inbox in the copy'
  inbox = link.inbox
  ActiveJob::Base.queue_adapter = :inline
  contact = Contact.create!(account: inbox.account, name: 'Upgrade rehearsal')
  contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.uuid)
  conversation = Conversation.create!(account: inbox.account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  raise "new bot conversation is #{conversation.status}, not pending" unless conversation.pending?
  conversation.messages.create!(account: inbox.account, inbox: inbox, sender: contact,
                                content: 'upgrade rehearsal probe', message_type: :incoming)
  raise 'bot conversation left pending after delivery' unless conversation.reload.pending?

  # The middleware answers with the bot's own access token: it must still be
  # accepted by the messages API. Delivery to the channel then fails, because
  # this network has no egress; only the API contract is checked.
  require 'net/http'
  uri = URI("http://127.0.0.1:3000/api/v1/accounts/#{inbox.account_id}/conversations/#{conversation.display_id}/messages")
  reply = Net::HTTP.post(uri, { content: 'upgrade rehearsal reply', message_type: 'outgoing' }.to_json,
                         'Content-Type' => 'application/json', 'api_access_token' => link.agent_bot.access_token.token)
  raise "bot token rejected by the messages API (#{reply.code})" unless reply.code == '200'
  raise 'bot reply not stored' unless conversation.messages.outgoing.where(content: 'upgrade rehearsal reply').exists?
  puts "blobs=#{blobs.size} readable bot_inbox=#{inbox.channel_type} conversation=pending bot_reply=200"
rescue StandardError => e
  warn "FAIL: #{e.class}: #{e.message.to_s[0, 200]}"
  exit 1
end
RUBY
bot_hits() { docker exec "$proj-receiver" sh -c "grep -c '^POST /webhooks/chatwoot$1\$' /tmp/hits 2>/dev/null || true"; }
delivered=$(bot_hits '')
[[ "${delivered:-0}" -ge 1 ]] || die "Agent Bot webhook did not reach the private endpoint"
log "rails: $(tail -n 1 "$logdir/runner.log"); bot webhook delivered ($delivered POST)"

# Negative control: the same probe with the SafeFetch switch off must be
# blocked (no delivery, conversation opened). It proves the check above
# measures the compose setting and not an unprotected code path.
dc exec -T -e SAFE_FETCH_ALLOW_PRIVATE_NETWORK=false chatwoot-rails bundle exec rails runner - \
  > "$logdir/negative.log" 2>&1 <<'RUBY' || die "negative control failed (see $logdir/negative.log)"
require 'logger'
Rails.logger = Logger.new(File::NULL)
ActiveRecord::Base.logger = nil
ActiveJob::Base.logger = Logger.new(File::NULL)
ActiveJob::Base.queue_adapter = :inline
inbox = AgentBotInbox.where(status: :active).first.inbox
contact = Contact.create!(account: inbox.account, name: 'Upgrade rehearsal negative control')
contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.uuid)
conversation = Conversation.create!(account: inbox.account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
conversation.messages.create!(account: inbox.account, inbox: inbox, sender: contact,
                              content: 'negative control', message_type: :incoming)
exit(conversation.reload.open? ? 0 : 1)
RUBY
sleep 5
[[ "$(bot_hits ' negative')" == 0 ]] || die "negative control: webhook was delivered with the switch off"
log "negative control: with the switch off the webhook is blocked and the conversation is opened"

for svc in chatwoot-rails chatwoot-sidekiq; do
  c=$(dc ps -q "$svc")
  log "$svc: $(docker inspect -f 'restarts={{.RestartCount}} oom={{.State.OOMKilled}}' "$c") mem=$(docker stats --no-stream --format '{{.MemUsage}}' "$c")"
done
log "PASS in ${SECONDS}s"
