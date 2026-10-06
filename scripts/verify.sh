#!/usr/bin/env bash
# Usage: verify.sh [client-id]  — checks Terraform can't do: each Repository reaches GitHub (/test) and has synced.
source "$(dirname "$0")/lib.sh"
load_env
command -v jq >/dev/null || die "jq not found (brew install jq)"

if [[ -n "${1:-}" ]]; then require_client "$1"; targets=("$1"); else targets=($(clients)); fi

# pairs of "base_url repo_name"
pairs=()
for c in "${targets[@]}"; do
  pairs+=("$DEV_URL $c-dev" "$(client_field "$c" prod_url) $c-prod")
done

for pair in "${pairs[@]}"; do
  read -r base name <<<"$pair"
  wait_healthy "$base"
  echo "→ testing connection for $name ($base)"
  result="$(api POST "$base" "$REPO_API/$name/test" || true)"
  if [[ "$(jq -r '.success' <<<"$result" 2>/dev/null || true)" != "true" ]]; then
    jq . <<<"$result" 2>/dev/null >&2 || echo "$result" >&2
    die "$name connection test failed (run tf.sh apply first; check token covers the repo and the branch exists)"
  fi
  echo "  ok"
done

echo "→ waiting for sync"
for _ in $(seq 1 30); do
  pending=()
  for pair in "${pairs[@]}"; do
    read -r base name <<<"$pair"
    state="$(api GET "$base" "$REPO_API/$name/status" | jq -r '.status.sync.state // empty')"
    [[ "$state" == success ]] || pending+=("$name=$state")
  done
  [[ ${#pending[@]} -eq 0 ]] && { echo "  all ${#pairs[@]} repositories synced"; exit 0; }
  sleep 2
done
die "sync did not reach success: ${pending[*]}"
