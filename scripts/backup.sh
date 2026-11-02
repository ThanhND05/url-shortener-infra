#!/usr/bin/env bash
set -Eeuo pipefail
APP_ROOT="${APP_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$APP_ROOT"
umask 077
mkdir -p backups
stamp=$(date -u +%Y%m%dT%H%M%SZ)
output="$APP_ROOT/backups/postgres-$stamp.dump"
temporary="$output.partial"
trap 'rm -f "$temporary"' EXIT
docker compose --env-file .env -f compose/compose.yml exec -T postgres \
  sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --no-owner --no-acl' > "$temporary"
[[ -s "$temporary" ]] || { echo 'Backup is empty' >&2; exit 1; }
docker compose --env-file .env -f compose/compose.yml exec -T postgres \
  pg_restore --list < "$temporary" >/dev/null
mv "$temporary" "$output"
(cd backups && sha256sum "$(basename "$output")" > "$(basename "$output").sha256")
echo "Backup verified: $output"
