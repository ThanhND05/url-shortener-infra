#!/usr/bin/env bash
set -Eeuo pipefail
APP_ROOT="${APP_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$APP_ROOT"
backup="${1:?Usage: restore.sh /path/to/backup.dump}"
target="${2:-restore_lab}"
[[ "$target" =~ ^restore_[a-z0-9_]+$ ]] || { echo 'Target must begin restore_' >&2; exit 1; }
[[ -f "$backup" && -f "$backup.sha256" ]] || { echo 'Missing dump/checksum' >&2; exit 1; }
(cd "$(dirname "$backup")" && sha256sum -c "$(basename "$backup").sha256")
dc() { docker compose --env-file .env -f compose/compose.yml "$@"; }
# createdb intentionally fails if target exists; no DROP DATABASE here.
dc exec -T postgres sh -c 'createdb -U "$POSTGRES_USER" "$1"' sh "$target"
dc exec -T postgres sh -c \
  'pg_restore -U "$POSTGRES_USER" -d "$1" --no-owner --no-acl --exit-on-error' sh "$target" < "$backup"
dc exec -T postgres sh -c \
  'psql -U "$POSTGRES_USER" -d "$1" -c "SELECT count(*) FROM link.links;"' sh "$target"
echo "Restored into $target; verify via a separate application instance next"
