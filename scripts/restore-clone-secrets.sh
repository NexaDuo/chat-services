#!/usr/bin/env bash
# restore-clone-secrets.sh <archive> [--dry-run] [--force] [--target DIR] [--allow RELPATH]...
# Restore the clone-local secrets archive made by backup-host.sh (issue #291)
# into the repo root (or --target). Accepts clone-secrets-<ts>.tar.gz and its
# encrypted forms (.gpg: needs the operator's private key in gpg; .age: needs
# AGE_IDENTITY=<identity file>). The archive is UNTRUSTED INPUT (it lives in a
# cloud-synced folder and public-key encryption does not authenticate): every
# entry must be a regular file whose relative path is in the allowlist (the default
# BACKUP_CLONE_SECRET_PATHS list below, extended only by explicit --allow flags);
# anything else (absolute/.. paths, symlinks, hardlinks, devices, .git/*) aborts
# before a single byte is written. Refuses to overwrite without --force.
# Never prints file contents.
set -euo pipefail
# Keep in sync with BACKUP_CLONE_SECRET_PATHS in backup-host.sh (a test checks it).
DEFAULT_ALLOW=(.env deploy/.env infrastructure/terraform/envs/production/terraform.tfvars infrastructure/terraform/envs/foundation/terraform.tfvars infrastructure/terraform/envs/tenant/terraform.tfvars .claude/settings.local.json skills-lock.json)
usage() { echo "uso: $0 <archive> [--dry-run] [--force] [--target DIR] [--allow RELPATH]..." >&2; exit 2; }
safe_rel() { [[ -n "$1" && "$1" != /* && "$1" != -* && "$1" != *..* && "$1" != .git && "$1" != .git/* ]]; }
ARCHIVE=""; DRY=0; FORCE=0
TARGET="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOW=("${DEFAULT_ALLOW[@]}")
while (( $# )); do
  case "$1" in
    --dry-run) DRY=1 ;;
    --force) FORCE=1 ;;
    --target) shift; [[ $# -gt 0 ]] || usage; TARGET="$1" ;;
    --allow) shift; [[ $# -gt 0 ]] || usage
      safe_rel "$1" || { echo "ERRO: --allow inválido: $1" >&2; exit 2; }
      ALLOW+=("$1") ;;
    -*) usage ;;
    *) [[ -z "$ARCHIVE" ]] || usage; ARCHIVE="$1" ;;
  esac
  shift
done
[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || { echo "ERRO: archive não encontrado: ${ARCHIVE:-<vazio>}" >&2; exit 2; }
[[ -d "$TARGET" ]] || { echo "ERRO: target inexistente: $TARGET" >&2; exit 2; }
TARGET="$(realpath -- "$TARGET")"

umask 077
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# Always work on a PRIVATE copy (0700 dir): validate and extract from the copy, never
# from the original path (a writer to the synced folder could swap it in between).
TARBALL="$WORK/a.tar.gz"
case "$ARCHIVE" in
  *.gpg) gpg --quiet --decrypt -o "$TARBALL" "$ARCHIVE" ;;
  *.age) [[ -n "${AGE_IDENTITY:-}" ]] || { echo "ERRO: defina AGE_IDENTITY=<arquivo de identidade age>" >&2; exit 2; }
         age -d -i "$AGE_IDENTITY" -o "$TARBALL" "$ARCHIVE" ;;
  *) cp -- "$ARCHIVE" "$TARBALL" ;;
esac
SHA_VALIDATED=""

mapfile -t ENTRIES < <(tar tzf "$TARBALL")
mapfile -t TYPES < <(tar tvzf "$TARBALL" | cut -c1)
[[ ${#ENTRIES[@]} -gt 0 ]] || { echo "ERRO: archive vazio." >&2; exit 1; }
[[ ${#ENTRIES[@]} -eq ${#TYPES[@]} ]] || { echo "ERRO: listagem inconsistente do archive (nomes estranhos?)." >&2; exit 1; }
dups="$(printf '%s\n' "${ENTRIES[@]}" | sort | uniq -d)"
[[ -z "$dups" ]] || { echo "ERRO: membros duplicados no archive recusados: $(tr '\n' ' ' <<<"$dups"); nada foi escrito." >&2; exit 1; }
bad=0
for i in "${!ENTRIES[@]}"; do
  e="${ENTRIES[$i]}"
  if [[ "${TYPES[$i]}" != "-" ]]; then echo "ERRO: entrada não-regular recusada: ${e} (tipo ${TYPES[$i]})" >&2; bad=1; continue; fi
  if ! safe_rel "$e"; then echo "ERRO: caminho inseguro recusado: ${e}" >&2; bad=1; continue; fi
  found=0
  for a in "${ALLOW[@]}"; do [[ "$e" == "$a" ]] && found=1; done
  if (( ! found )); then echo "ERRO: entrada fora da allowlist recusada: ${e}" >&2; bad=1; continue; fi
  # No existing symlinked directory component may redirect the write outside TARGET.
  resolved="$(realpath -m -- "$TARGET/$e")"
  if [[ "$resolved" != "$TARGET"/* ]]; then echo "ERRO: ${e} resolveria para fora do target" >&2; bad=1; fi
done
(( bad == 0 )) || { echo "ERRO: archive recusado; nada foi escrito." >&2; exit 1; }
SHA_VALIDATED="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
# Test-only hook: runs between validation and extraction (receives the private copy path)
# to prove source swaps/tampering are harmless/detected. INERT unless BACKUP_TEST_MODE=1.
if [[ -n "${RESTORE_TEST_HOOK:-}" ]]; then
  if [[ "${BACKUP_TEST_MODE:-0}" == "1" ]]; then
    echo "AVISO: BACKUP_TEST_MODE=1: RESTORE_TEST_HOOK ativo (nunca em produção)." >&2
    bash -c "$RESTORE_TEST_HOOK" _ "$TARBALL"
  else
    echo "AVISO: RESTORE_TEST_HOOK ignorado (exige BACKUP_TEST_MODE=1)." >&2
  fi
fi

clash=0
for e in "${ENTRIES[@]}"; do
  if [[ -e "$TARGET/$e" || -L "$TARGET/$e" ]]; then echo "existe: $e" >&2; clash=1; fi
done
if (( clash && ! FORCE )); then
  echo "ERRO: arquivos já existem em ${TARGET}; use --force para sobrescrever." >&2
  exit 1
fi
if (( DRY )); then
  echo "dry-run: restauraria em ${TARGET}:"; printf '  %s\n' "${ENTRIES[@]}"
  exit 0
fi
keep=(--keep-old-files); (( FORCE )) && keep=(--unlink-first)
[[ "$(sha256sum "$TARBALL" | cut -d' ' -f1)" == "$SHA_VALIDATED" ]] || { echo "ERRO: archive mudou após a validação; abortado." >&2; exit 1; }
tar xzf "$TARBALL" -C "$TARGET" --no-same-owner --no-same-permissions "${keep[@]}" -- "${ENTRIES[@]}"
# Ignore archive mode bits: regular files become 0600 (dirs created by tar are 0700, umask 077).
for e in "${ENTRIES[@]}"; do chmod 600 "$TARGET/$e"; done
echo "restaurado em ${TARGET}: ${#ENTRIES[@]} entradas"
echo "AVISO: o conteúdo restaurado (.env, .claude/settings.local.json, ...) NÃO é autenticado; revise antes de usar." >&2
