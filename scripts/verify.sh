#!/usr/bin/env bash
# Checks Terraform can't do: Grafana reaches GitHub (/test) and both instances finished a sync.
source "$(dirname "$0")/lib.sh"
load_env
command -v jq >/dev/null || die "jq not found (brew install jq)"

check_repo() {
  local base="$1" name="$2" result
  wait_healthy "$base"
  echo "→ testing connection for $name"
  result="$(api POST "$base" "$REPO_API/$name/test" || true)"
  if [[ "$(jq -r '.success' <<<"$result" 2>/dev/null || true)" != "true" ]]; then
    jq . <<<"$result" 2>/dev/null >&2 || echo "$result" >&2
    die "$name connection test failed (run ./scripts/tf.sh apply first; check token permissions and that the branch exists)"
  fi
  echo "  ok"
}

check_repo "$DEV_URL"  poc-dev
check_repo "$PROD_URL" poc-prod

echo "→ waiting for sync"
for _ in $(seq 1 30); do
  d="$(api GET "$DEV_URL"  "$REPO_API/poc-dev/status"  | jq -r '.status.sync.state // empty')"
  p="$(api GET "$PROD_URL" "$REPO_API/poc-prod/status" | jq -r '.status.sync.state // empty')"
  [[ "$d" == "success" && "$p" == "success" ]] && { echo "  dev=$d prod=$p"; exit 0; }
  sleep 2
done
die "sync did not reach success (dev=$d prod=$p)"
