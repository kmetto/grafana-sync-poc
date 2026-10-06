#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_URL="http://localhost:3000"
PROD_URL="http://localhost:3001"
REPO_API="/apis/provisioning.grafana.app/v0alpha1/namespaces/default/repositories"

die() { echo "ERROR: $*" >&2; exit 1; }

load_env() {
  [[ -f "$ROOT/.env" ]] || die ".env not found — copy .env.example to .env and fill it in"
  set -a; source "$ROOT/.env"; set +a
  [[ -n "${GITHUB_TOKEN:-}" ]] || die "GITHUB_TOKEN is empty in .env"
  [[ -n "${GITHUB_REPO_URL:-}" ]] || die "GITHUB_REPO_URL is empty in .env"
  GF_ADMIN_USER="${GF_ADMIN_USER:-admin}"
  GF_ADMIN_PASSWORD="${GF_ADMIN_PASSWORD:-admin}"
}

wait_healthy() {
  local url="$1"
  for _ in $(seq 1 90); do
    curl -sf "$url/api/health" >/dev/null && return 0
    sleep 1
  done
  die "Grafana at $url not healthy after 90s"
}

# api METHOD BASE_URL PATH [BODY_FILE] — prints body, fails on HTTP >= 400
api() {
  local method="$1" base="$2" path="$3" body="${4:-}" out code
  out="$(mktemp)"
  local args=(-s -o "$out" -w '%{http_code}' -u "$GF_ADMIN_USER:$GF_ADMIN_PASSWORD" -X "$method" "$base$path")
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/yaml' --data-binary "@$body")
  code="$(curl "${args[@]}")"
  cat "$out"; rm -f "$out"
  [[ "$code" -lt 400 ]]
}
