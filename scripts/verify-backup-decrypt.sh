#!/usr/bin/env bash
# verify-backup-decrypt.sh <clone-secrets-<ts>.tar.gz.gpg|.age|.tar.gz>
# Read-only proof that an off-host secrets archive is actually RECOVERABLE: decrypt with
# the offline private key, validate and extract into a throwaway dir, check .env is
# present, delete the scratch dir. Never prints content. Run this once after the first
# encrypted run and BEFORE relying on the remote plaintext purge (issue #291): the purge
# proves presence on the remote, not that you can still decrypt.
set -euo pipefail
ARCHIVE="${1:?uso: $0 <archive>}"
SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
bash "$(dirname "${BASH_SOURCE[0]}")/restore-clone-secrets.sh" "$ARCHIVE" --target "$SCRATCH" >/dev/null
[[ -s "$SCRATCH/.env" ]] || { echo "ERRO: .env ausente/vazio no archive decriptado." >&2; exit 1; }
echo "OK: $(find "$SCRATCH" -type f | wc -l) arquivo(s) decriptado(s) e válidos (.env presente); scratch removido."
