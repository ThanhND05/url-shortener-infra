#!/usr/bin/env bash
# Separate credentials for kind/EKS databases. Never source the env file as shell code.
set -Eeuo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
action="${1:?Usage: k8s-lab-env.sh init|apply .lab/ENV/secrets.env [namespace context]}"
env_file="${2:?Specify a private env file under .lab/}"
[[ "$env_file" == .lab/* && "$env_file" != *..* ]] || { echo 'Use a path under .lab/' >&2; exit 1; }
umask 077
if [[ "$action" == init ]]; then
  [[ ! -e "$env_file" ]] || { echo 'Env exists; do not regenerate credentials for an existing PVC' >&2; exit 1; }
  mkdir -p "$(dirname "$env_file")"
  temporary=$(mktemp "$(dirname "$env_file")/pending.XXXXXX")
  trap 'rm -f "$temporary"' EXIT
  {
    printf 'DB_NAME=url_shortener\nDB_USERNAME=urlshortener\n'
    for key in DB_PASSWORD JWT_SECRET SUPER_ADMIN_PASSWORD ADMIN_PASSWORD VNPAY_HASH_SECRET; do
      printf '%s=%s\n' "$key" "$(openssl rand -hex 32)"
    done
    printf 'SUPER_ADMIN_EMAIL=superadmin@lab.example.com\nADMIN_EMAIL=admin@lab.example.com\nVNPAY_TMN_CODE=LAB_DISABLED\n'
  } > "$temporary"
  ln "$temporary" "$env_file"
  echo 'Created private lab env. Keep it for this database; never commit it.'
elif [[ "$action" == apply ]]; then
  namespace="${3:?Specify namespace}"
  context="${4:?Specify expected kubectl context}"
  [[ "$(kubectl config current-context)" == "$context" ]] || { echo 'Wrong context' >&2; exit 1; }
  [[ -s "$env_file" ]] || { echo 'Missing env' >&2; exit 1; }
  kubectl -n "$namespace" create secret generic app-secrets --from-env-file="$env_file" \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo 'Action must be init or apply' >&2
  exit 1
fi
