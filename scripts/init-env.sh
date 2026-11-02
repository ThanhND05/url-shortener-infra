#!/usr/bin/env bash
set -Eeuo pipefail
APP_ROOT="${APP_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$APP_ROOT"
[[ ! -e .env ]] || { echo '.env exists; edit it instead of replacing secrets' >&2; exit 1; }
umask 077
temporary=$(mktemp "$APP_ROOT/.env.pending.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  case "$line" in
    *=REPLACE_WITH_RANDOM_HEX|*=REPLACE_WITH_AT_LEAST_32_RANDOM_BYTES)
      printf '%s=%s\n' "${line%%=*}" "$(openssl rand -hex 32)" ;;
    *) printf '%s\n' "$line" ;;
  esac
done < .env.example > "$temporary"
# Hard link fails rather than overwriting if another process created .env.
ln "$temporary" .env
echo 'Created private .env. Set public URLs before starting app.'
