#!/usr/bin/env bash
# Run terraform in ./terraform with credentials from .env (never written to tfvars or state).
source "$(dirname "$0")/lib.sh"
load_env
export TF_VAR_github_token="$GITHUB_TOKEN"
export TF_VAR_repo_url="$GITHUB_REPO_URL"
export TF_VAR_grafana_auth="$GF_ADMIN_USER:$GF_ADMIN_PASSWORD"
exec terraform -chdir="$ROOT/terraform" "$@"
