#!/usr/bin/env bash
set -Eeuo pipefail
APP_ROOT="${APP_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
[[ -f "$APP_ROOT/releases/previous.env" ]] || { echo 'No previous release' >&2; exit 1; }
exec bash "$APP_ROOT/scripts/deploy.sh" "$APP_ROOT/releases/previous.env"
