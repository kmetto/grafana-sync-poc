#!/usr/bin/env bash
# Create and seed client repos from clients.json. Idempotent: existing repos/branches are left alone.
source "$(dirname "$0")/lib.sh"
command -v gh >/dev/null || die "gh not found"

seed_dashboard() {
  local id="$1" title="$2"
  jq -n --arg uid "$id-sample" --arg title "$title — Sample" '{
    uid: $uid, title: $title, schemaVersion: 41, tags: ["git-sync-poc"],
    time: {from: "now-6h", to: "now"},
    panels: [{id: 1, type: "text", title: "Hello from Git", gridPos: {h: 6, w: 12, x: 0, y: 0},
              options: {mode: "markdown", content: ("Managed by **Git Sync** for " + $title + ".")}}]
  }'
}

for id in $(clients); do
  repo="$(client_field "$id" repo)"; title="$(client_field "$id" title)"
  if gh repo view "$repo" >/dev/null 2>&1; then
    echo "→ $repo exists"
  else
    echo "→ creating $repo"
    gh repo create "$repo" --public --description "Grafana dashboards for $title (Git Sync POC)" >/dev/null
  fi

  if gh api "repos/$repo/branches/main" >/dev/null 2>&1; then
    echo "  main exists"
  else
    echo "  seeding main"
    gh api -X PUT "repos/$repo/contents/grafana/sample-dashboard.json" \
      -f message="chore: seed sample dashboard" \
      -f content="$(seed_dashboard "$id" "$title" | base64 | tr -d '\n')" >/dev/null
    [[ "$(gh api "repos/$repo" --jq .default_branch)" == main ]] || die "$repo default branch is not main"
  fi

  if gh api "repos/$repo/branches/dev" >/dev/null 2>&1; then
    echo "  dev exists"
  else
    echo "  creating dev from main"
    sha="$(gh api "repos/$repo/git/ref/heads/main" --jq .object.sha)"
    gh api -X POST "repos/$repo/git/refs" -f ref=refs/heads/dev -f sha="$sha" >/dev/null
  fi
done
