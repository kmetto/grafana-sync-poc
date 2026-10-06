#!/usr/bin/env bash
# Usage: tf.sh dev <terraform args...>
#        tf.sh client-prod <client-id> <terraform args...>
# Credentials come from .env and are passed as TF_VAR_* (never written to tfvars or state).
source "$(dirname "$0")/lib.sh"
load_env
export TF_VAR_github_token="$GITHUB_TOKEN"
export TF_VAR_grafana_auth="$GF_ADMIN_USER:$GF_ADMIN_PASSWORD"

root="${1:-}"; shift || true
case "$root" in
  dev)
    dir="$ROOT/terraform/dev"
    [[ -d "$dir/.terraform" ]] || terraform -chdir="$dir" init -input=false >/dev/null
    ;;
  client-prod)
    client="${1:-}"; shift || true
    require_client "$client"
    dir="$ROOT/terraform/client-prod"
    [[ -d "$dir/.terraform" ]] || terraform -chdir="$dir" init -input=false >/dev/null
    terraform -chdir="$dir" workspace select -or-create "$client" >/dev/null
    ;;
  *) die "usage: tf.sh dev <args> | tf.sh client-prod <client-id> <args>" ;;
esac
exec terraform -chdir="$dir" "$@"
