#!/usr/bin/env bash
set -Eeuo pipefail
APP_ROOT="${APP_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$APP_ROOT"
candidate="${1:?Usage: deploy.sh /absolute/path/to/release.env}"
[[ -f "$candidate" && -f .env && -f .smoke.json ]] || { echo 'Missing release/env/smoke fixture' >&2; exit 1; }
mkdir -p releases
exec 9>releases/deploy.lock
flock -n 9 || { echo 'Another deploy is running' >&2; exit 1; }
pending=$(mktemp "$APP_ROOT/releases/pending.XXXXXX")
trap 'rm -f "$pending"' EXIT
cp "$candidate" "$pending"
chmod 600 "$pending"
declare -A images=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  [[ -z "$line" || "$line" == \#* ]] && continue
  [[ "$line" == *=* ]] || { echo 'Invalid release line' >&2; exit 1; }
  key="${line%%=*}"
  value="${line#*=}"
  [[ "$key" == BACKEND_IMAGE || "$key" == FRONTEND_IMAGE ]] || exit 1
  [[ -z "${images[$key]+present}" ]] || { echo 'Duplicate image key' >&2; exit 1; }
  [[ "$value" =~ ^[a-z0-9./_-]+(:[A-Za-z0-9_.-]+|@sha256:[a-f0-9]{64})$ ]] || { echo 'Invalid image reference' >&2; exit 1; }
  images[$key]="$value"
done < "$pending"
[[ ${#images[@]} == 2 ]] || { echo 'Both images are required' >&2; exit 1; }
dc() {
  docker compose --env-file .env --env-file "$1" -f compose/compose.yml "${@:2}"
}
apply_release() {
  local manifest="$1"
  if [[ "${PULL_IMAGES:-1}" == 1 ]]; then
    dc "$manifest" pull app frontend || return 1
  fi
  dc "$manifest" up -d --no-deps --force-recreate app frontend || return 1
  for attempt in $(seq 1 60); do
    if curl --silent --fail --max-time 3 http://127.0.0.1:8080/healthz >/dev/null; then
      bash scripts/smoke.sh run http://127.0.0.1:8080 && return 0
    fi
    sleep 5
  done
  return 1
}
if apply_release "$pending"; then
  if [[ -f releases/current.env ]]; then
    cp releases/current.env releases/previous.env
  fi
  cp "$pending" releases/current.env
  cp "$pending" release.env
  chmod 600 releases/*.env release.env
  echo "PASS deployment $(date -u +%FT%TZ)"
else
  echo 'FAIL candidate; attempting previous successful release' >&2
  if [[ -f releases/current.env ]] && apply_release releases/current.env; then
    echo 'Previous release restored; deployment remains failed' >&2
  else
    echo 'Recovery failed; inspect logs and database compatibility' >&2
  fi
  exit 1
fi
