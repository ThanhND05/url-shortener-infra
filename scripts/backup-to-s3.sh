#!/usr/bin/env bash
set -Eeuo pipefail
APP_ROOT="${APP_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$APP_ROOT"
: "${BACKUP_BUCKET:?Set BACKUP_BUCKET to your private backup bucket}"
mkdir -p backups
exec 8>backups/backup.lock
flock -n 8 || { echo 'Backup already running' >&2; exit 1; }
result=$(bash scripts/backup.sh)
printf '%s\n' "$result"
dump="${result##*Backup verified: }"
[[ -f "$dump" && "$dump" == "$APP_ROOT"/backups/*.dump ]] || { echo 'Unexpected dump path' >&2; exit 1; }
aws s3 cp "$dump" "s3://$BACKUP_BUCKET/backups/$(basename "$dump")" --only-show-errors
aws s3 cp "$dump.sha256" "s3://$BACKUP_BUCKET/backups/$(basename "$dump").sha256" --only-show-errors
date -u +%FT%TZ > backups/last-offhost-success.txt
echo 'PASS off-host upload'
