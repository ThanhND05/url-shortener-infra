#!/usr/bin/env bash
set -Eeuo pipefail
APP_ROOT="${APP_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$APP_ROOT"
mode="${1:-run}"
base="${2:-http://127.0.0.1:8080}"
base="${base%/}"
[[ "$mode" == init || "$mode" == run ]] || { echo 'Usage: smoke.sh init|run [base-url]' >&2; exit 1; }
umask 077
work=$(mktemp -d)
trap 'rm -f -- "$work"/*; rmdir -- "$work"' EXIT

api() {
  local method="$1" path="$2" input="$3" expected="$4" token="${5:-}"
  local args=(--silent --show-error --connect-timeout 5 --max-time 20
    --output "$work/response.json" --write-out '%{http_code}'
    --request "$method" --header 'Content-Type: application/json')
  [[ "$input" == - ]] || args+=(--data-binary "@$input")
  if [[ -n "$token" ]]; then
    # Keep the token out of curl argv; the private temp file is removed on exit.
    printf 'Authorization: Bearer %s\n' "$token" > "$work/auth-header"
    args+=(--header "@$work/auth-header")
  fi
  local status
  status=$(curl "${args[@]}" "$base$path") || return 1
  [[ "$status" == "$expected" ]] || { echo "FAIL $method $path: HTTP $status, expected $expected" >&2; return 1; }
  jq -e '.success == true' "$work/response.json" >/dev/null
}

curl --fail --silent --show-error --max-time 10 "$base/healthz" > "$work/health.json"
jq -e '.status == "UP"' "$work/health.json" >/dev/null
if [[ "$mode" == init ]]; then
  [[ ! -e .smoke.json ]] || { echo 'Fixture exists; use run instead' >&2; exit 1; }
  email="smoke-$(openssl rand -hex 6)@lab.example.com"
  password=$(openssl rand -hex 24)
  jq -n --arg email "$email" --arg password "$password" \
    '{email:$email,password:$password,displayName:"DevOps Smoke"}' > "$work/register.json"
  api POST /api/v1/auth/register "$work/register.json" 201
  token=$(jq -er '.data.accessToken' "$work/response.json")
  printf '%s\n' '{"originalUrl":"https://example.com/devops-lab","title":"Persistent smoke link","redirectType":302}' > "$work/link.json"
  api POST /api/v1/links "$work/link.json" 201 "$token"
  jq --arg email "$email" --arg password "$password" \
    '{email:$email,password:$password,shortCode:.data.shortCode,publicId:.data.publicId,originalUrl:.data.originalUrl}' \
    "$work/response.json" > "$work/state.json"
  # Atomic no-clobber creation: do not replace an existing fixture.
  (set -o noclobber; cat "$work/state.json" > .smoke.json)
fi
[[ -f .smoke.json ]] || { echo 'Run smoke.sh init first' >&2; exit 1; }
jq '{email,password}' .smoke.json > "$work/login.json"
api POST /api/v1/auth/login "$work/login.json" 200
token=$(jq -er '.data.accessToken' "$work/response.json")
id=$(jq -er '.publicId' .smoke.json)
code=$(jq -er '.shortCode' .smoke.json)
target=$(jq -er '.originalUrl' .smoke.json)
[[ "$id" =~ ^[a-fA-F0-9-]+$ && "$code" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 1
api GET "/api/v1/links/$id" - 200 "$token"
jq -e --arg target "$target" '.data.originalUrl == $target' "$work/response.json" >/dev/null
status=$(curl --silent --show-error --max-time 15 --dump-header "$work/headers" \
  --output /dev/null --write-out '%{http_code}' "$base/r/$code")
location=$(awk 'tolower($1)=="location:" {sub(/\r$/, ""); sub(/^[^:]+:[[:space:]]*/, ""); print; exit}' "$work/headers")
[[ "$status" == 302 && "$location" == "$target" ]] || { echo 'FAIL redirect status/Location' >&2; exit 1; }
echo 'PASS health, login, persisted link, redirect (without following target)'
