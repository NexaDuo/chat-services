#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_EXAMPLE="$ROOT_DIR/.env.example"
ENV_FILE="$ROOT_DIR/.env"

if [[ ! -f "$ENV_EXAMPLE" ]]; then
  echo "Missing $ENV_EXAMPLE" >&2
  exit 1
fi

if [[ -f "$ENV_FILE" ]]; then
  echo "$ENV_FILE already exists. Remove it to regenerate." >&2
  exit 1
fi

rand_hex() {
  openssl rand -hex "$1"
}

secret_hex_16="$(rand_hex 16)"
secret_hex_32="$(rand_hex 32)"
secret_hex_64="$(rand_hex 64)"

cp "$ENV_EXAMPLE" "$ENV_FILE"
sed -i \
  -e "s|\\\${secret_hex_16}|${secret_hex_16}|g" \
  -e "s|\\\${secret_hex_32}|${secret_hex_32}|g" \
  -e "s|\\\${secret_hex_64}|${secret_hex_64}|g" \
  "$ENV_FILE"

echo "Created $ENV_FILE"
