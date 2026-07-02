#!/usr/bin/env bash
# dev-claude.sh — launch Claude Code for this repo through Headroom (token saver),
# preconfigured, so the team's setup is reproducible in the repo instead of living
# in each person's ~/.zshrc.
#
# Usage:
#   ./dev-claude.sh                 # cache mode + skip-permissions (defaults)
#   HEADROOM_MODE=token ./dev-claude.sh
#   SKIP_PERMISSIONS=0 ./dev-claude.sh   # keep the permission prompts
#   ./dev-claude.sh --resume        # extra args are passed straight to `claude`
set -euo pipefail

# Headroom compression mode:
#   cache  → freezes prior turns to maximize prefix-cache hits; best fidelity +
#            cost balance for edit-heavy work (recommended — token mode was
#            rewriting history aggressively and garbling file reads, see PR #123).
#   token  → most aggressive compression (max raw token savings, lower fidelity).
export HEADROOM_MODE="${HEADROOM_MODE:-cache}"

# Group Headroom stats/savings under this project.
export ANTHROPIC_CUSTOM_HEADERS="${ANTHROPIC_CUSTOM_HEADERS:-X-Headroom-Project: chat-services}"

# Skip permission prompts by default (matches the current workflow).
# Note: this auto-approves tool calls — opt out with SKIP_PERMISSIONS=0 if you
# want the prompts back.
SKIP_PERMISSIONS="${SKIP_PERMISSIONS:-1}"
claude_args=()
[ "$SKIP_PERMISSIONS" = "1" ] && claude_args+=(--dangerously-skip-permissions)

if ! command -v headroom >/dev/null 2>&1; then
  echo "⚠ headroom not found on PATH — launching plain Claude Code (no token saver)." >&2
  echo "  Install it (claude-token-saver) to get compression + prefix-cache savings." >&2
  exec claude "${claude_args[@]}" "$@"
fi

echo "▶ Claude Code via Headroom — mode=${HEADROOM_MODE}, skip-permissions=${SKIP_PERMISSIONS}"
exec headroom wrap claude "${claude_args[@]}" "$@"
