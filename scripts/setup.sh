#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
load_env
command -v jq >/dev/null || die "jq not found (brew install jq)"

apply_repo() {
  local base="$1" name="$2" tmpl="$3" rendered
  wait_healthy "$base"
  local got
  got="$(mktemp)"
  api GET "$base" "$REPO_API/$name" >"$got" 2>&1 || true
  local method=POST path="$REPO_API" verb=create
  if [[ "$API_CODE" == 404 ]]; then
    echo "→ creating $name on $base"
  elif [[ "$API_CODE" =~ ^2 ]]; then
    echo "→ $name exists on $base, updating"
    method=PUT path="$REPO_API/$name" verb=update
  else
    cat "$got" >&2; rm -f "$got"
    die "lookup of $name on $base failed (HTTP $API_CODE)"
  fi
  rm -f "$got"

  rendered="$(mktemp)"
  perl -pe 's/\$\{(GITHUB_REPO_URL|GITHUB_TOKEN)\}/$ENV{$1}/g' < "$tmpl" > "$rendered"
  local resp
  resp="$(api "$method" "$base" "$path" "$rendered")" || { rm -f "$rendered"; echo "$resp" >&2; die "$verb of $name failed"; }
  rm -f "$rendered"

  echo "→ testing connection for $name"
  local result
  result="$(api POST "$base" "$REPO_API/$name/test" || true)"
  if [[ "$(jq -r '.success' <<<"$result" 2>/dev/null || true)" != "true" ]]; then
    jq . <<<"$result" 2>/dev/null >&2 || echo "$result" >&2
    die "$name connection test failed (check token permissions and that branch exists)"
  fi
  echo "  ok"
}

apply_repo "$DEV_URL"  poc-dev  "$ROOT/repos/dev.yaml"
apply_repo "$PROD_URL" poc-prod "$ROOT/repos/prod.yaml"

echo "→ waiting for first sync"
for _ in $(seq 1 30); do
  d="$(api GET "$DEV_URL"  "$REPO_API/poc-dev/status"  | jq -r '.status.sync.state // empty')"
  p="$(api GET "$PROD_URL" "$REPO_API/poc-prod/status" | jq -r '.status.sync.state // empty')"
  [[ "$d" == "success" && "$p" == "success" ]] && { echo "  dev=$d prod=$p"; exit 0; }
  sleep 2
done
die "sync did not reach success (dev=$d prod=$p)"
