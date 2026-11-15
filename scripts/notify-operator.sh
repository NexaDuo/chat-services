#!/usr/bin/env bash
# notify-operator.sh <title> <message> [throttle-key]
# Operator-visible push for this WSL host (issue #291): a Windows toast via
# powershell.exe (built-in WinRT, no module/credentials/SMTP). It must work from
# cron's minimal PATH, so powershell.exe is resolved by ABSOLUTE path
# (NOTIFY_POWERSHELL overrides and, when set, is used exclusively). NOTIFY_CMD
# overrides everything (tests, future ntfy/Slack hook): `$NOTIFY_CMD <title> <msg>`.
# Throttled per key (default 6h). Best effort: always exits 0 so a notifier problem
# never masks the failure being reported, BUT an undelivered notification is never
# silent: it is logged and recorded in <state>/.notify-undelivered (shown by
# `run-stack.sh preflight`). Never pass secrets in title/message.
set -uo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:/mnt/c/Windows/System32:${PATH:-}"
title="${1:-NexaDuo}"; msg="${2:-}"; key="${3:-default}"
state="${NOTIFY_STATE_DIR:-${HOME}/nexaduo-local}"
throttle="${NOTIFY_THROTTLE_SECONDS:-21600}"
stamp="${state}/.notify-${key//[^A-Za-z0-9_-]/_}"
mkdir -p "$state" 2>/dev/null || true
now="$(date +%s)"
if [[ -f "$stamp" ]]; then
  last="$(cat "$stamp" 2>/dev/null || echo 0)"
  if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last < throttle )); then exit 0; fi
fi
ps_bin="${NOTIFY_POWERSHELL-}"
if [[ -z "${NOTIFY_POWERSHELL+x}" ]]; then
  ps_bin="$(command -v powershell.exe 2>/dev/null || true)"
  [[ -n "$ps_bin" ]] || ps_bin="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
fi
sent=0
if [[ -n "${NOTIFY_CMD:-}" ]]; then
  $NOTIFY_CMD "$title" "$msg" && sent=1
elif [[ -x "$ps_bin" ]]; then
  NOTIFY_TITLE="$title" NOTIFY_MSG="$msg" WSLENV="NOTIFY_TITLE:NOTIFY_MSG${WSLENV:+:$WSLENV}" \
    timeout 20 "$ps_bin" -NoProfile -NonInteractive -Command '
$null=[Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]
$x=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$t=$x.GetElementsByTagName("text")
$null=$t.Item(0).AppendChild($x.CreateTextNode($env:NOTIFY_TITLE))
$null=$t.Item(1).AppendChild($x.CreateTextNode($env:NOTIFY_MSG))
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("NexaDuo Backup").Show([Windows.UI.Notifications.ToastNotification]::new($x))' \
    >/dev/null 2>&1 && sent=1
fi
if (( sent )); then
  echo "$now" > "$stamp" 2>/dev/null || true
  rm -f "${state}/.notify-undelivered" 2>/dev/null || true
else
  echo "notify-operator: NOT DELIVERED: ${title} (powershell: ${ps_bin:-none}; set NOTIFY_CMD/NOTIFY_POWERSHELL)" >&2
  printf '[%s] NOT DELIVERED: %s | %s\n' "$(date -Is)" "$title" "$msg" > "${state}/.notify-undelivered" 2>/dev/null || true
fi
exit 0
