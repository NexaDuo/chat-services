#!/usr/bin/env bash
# Shared by the host health check and the isolated storage-upgrade regression.
# NOT /ready: on the live ring-less single-binary it returns 503 while Tempo is
# fully functional (issue #158, re-observed 2026-10-01 on 2.6.1 with every
# /status/services entry Running). /api/echo is Tempo's own query-path
# liveness endpoint and must answer exactly "echo".
tempo_ready() {
  [[ "$(docker exec "$1" wget -qO- -T 5 http://tempo:3200/api/echo 2>/dev/null)" == echo ]]
}
