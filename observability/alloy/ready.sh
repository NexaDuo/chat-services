#!/usr/bin/env bash
# Real HTTP readiness, not just TCP. Alloy's Ubuntu image has bash + timeout.
set -euo pipefail
exec 3<>/dev/tcp/127.0.0.1/12345
printf 'GET /-/ready HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3
IFS= read -r status <&3
[[ "$status" == 'HTTP/1.1 200 '* || "$status" == 'HTTP/1.0 200 '* ]]
