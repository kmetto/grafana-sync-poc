# Grafana Git Sync POC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two Grafana instances in Docker — dev commits dashboard changes to branch `dev` of a GitHub repo, prod reads branch `main` read-only — with promotion via PR `dev → main`.

**Architecture:** Native Grafana Git Sync on both instances. Each gets one `Repository` resource (`provisioning.grafana.app/v0alpha1`) pointing at the same GitHub repo and `path: grafana/`, differing only in branch and workflows. A bash setup script creates the resources via the Grafana API; sync is by polling every 30s.

**Tech Stack:** Docker Compose, `grafana/grafana:13.2.3`, bash + curl + `envsubst` (gettext) + `jq`, `gh` CLI, GitHub fine-grained PAT.

**Spec:** `docs/superpowers/specs/2026-10-06-grafana-git-sync-poc-design.md`

## Global Constraints

- Git host: `https://github.com/kmetto/grafana-sync-poc` (public), local repo pushed as `origin`.
- Branches: `dev` written by dev Grafana; `main` read by prod Grafana.
- Ports: dev `3000`, prod `3001`.
- Image: `grafana/grafana:13.2.3` (verified 2026-10-06: provisioning API is on by default, no feature toggles needed).
- Repository API: `POST /apis/provisioning.grafana.app/v0alpha1/namespaces/default/repositories`.
- Sync: `enabled: true`, `intervalSeconds: 30`, `target: folder`, `path: grafana/`.
- dev `workflows: [write]`; prod `workflows: []` (empty = read-only, per API schema).
- Token lives only in `.env` (gitignored); never committed, never printed.
- Admin credentials for POC: `admin` / `admin` (set via env, documented in `.env.example`).

## Review Focus

1. `GITHUB_TOKEN` missing/empty in `.env` → `setup.sh` must exit non-zero with a clear message before calling any API (tested in Task 3).
2. `setup.sh` rerun after Repository already exists → must update (PUT) instead of failing with 409 (tested in Task 3).
3. Writing a file through prod's Repository → must be rejected because prod is read-only (tested in Task 4 `e2e.sh`).
4. Branch `dev` missing on GitHub → Repository test endpoint reports failure; `setup.sh` must surface it and exit non-zero (tested in Task 3 via `/test` health check).
5. Grafana not up yet when `setup.sh` runs → script waits up to 90s, then fails clearly (tested in Task 3).

---

## File Structure

| File | Responsibility |
|---|---|
| `.gitignore` | ignore `.env`, `.idea/`, `node_modules/` |
| `.env.example` | documents required env vars |
| `docker-compose.yml` | two Grafana services |
| `repos/dev.yaml`, `repos/prod.yaml` | Repository resource templates (envsubst placeholders) |
| `scripts/lib.sh` | shared helpers: load env, wait for health, API call wrapper |
| `scripts/setup.sh` | create/update Repository on both instances, run health test, print status |
| `scripts/e2e.sh` | automated demo: commit via dev → PR → merge → assert in prod |
| `grafana/sample-dashboard.json` | seed dashboard so first sync has content |
| `README.md` | how to run + manual UI demo |

---

### Task 1: Repo bootstrap and push to GitHub

**Files:**
- Create: `.gitignore`, `.env.example`, `grafana/sample-dashboard.json`

**Interfaces:**
- Produces: GitHub repo with branches `main` and `dev` (identical at start), both containing `grafana/sample-dashboard.json`. Env var names: `GITHUB_TOKEN`, `GITHUB_REPO_URL`, `GF_ADMIN_USER`, `GF_ADMIN_PASSWORD`.

- [ ] **Step 1: Write `.gitignore`**

```gitignore
.env
.idea/
node_modules/
```

- [ ] **Step 2: Write `.env.example`**

```dotenv
# GitHub fine-grained PAT for kmetto/grafana-sync-poc
# Permissions: Contents RW, Pull requests RW, Metadata R, Administration R, Webhooks RW
GITHUB_TOKEN=
GITHUB_REPO_URL=https://github.com/kmetto/grafana-sync-poc
GF_ADMIN_USER=admin
GF_ADMIN_PASSWORD=admin
```

- [ ] **Step 3: Write `grafana/sample-dashboard.json`**

```json
{
  "uid": "sample-dashboard",
  "title": "Sample Dashboard",
  "schemaVersion": 41,
  "tags": ["git-sync-poc"],
  "time": { "from": "now-6h", "to": "now" },
  "panels": [
    {
      "id": 1,
      "type": "text",
      "title": "Hello from Git",
      "gridPos": { "h": 6, "w": 12, "x": 0, "y": 0 },
      "options": { "mode": "markdown", "content": "This dashboard is managed by **Git Sync**." }
    }
  ]
}
```

- [ ] **Step 4: Commit and push `main`, create `dev`**

`index.js` and `package.json` are staged leftovers from the IDE template; keep them out of the POC commit (unstage only, do not delete):

```bash
git restore --staged index.js package.json
git add .gitignore .env.example grafana/sample-dashboard.json
git commit -m "chore: bootstrap Git Sync POC repo"
git branch -M main
git remote add origin https://github.com/kmetto/grafana-sync-poc.git
git push -u origin main
git push origin main:dev
```

- [ ] **Step 5: Verify**

Run: `git ls-remote origin`
Expected: two lines, `refs/heads/main` and `refs/heads/dev`, same SHA.

---

### Task 2: Docker Compose with two Grafana instances

**Files:**
- Create: `docker-compose.yml`

**Interfaces:**
- Produces: `grafana-dev` on `http://localhost:3000`, `grafana-prod` on `http://localhost:3001`, admin creds from `.env`.

- [ ] **Step 1: Write the failing check**

Run: `curl -sf localhost:3000/api/health && curl -sf localhost:3001/api/health`
Expected: FAIL (connection refused) — nothing running yet.

- [ ] **Step 2: Write `docker-compose.yml`**

```yaml
x-grafana: &grafana
  image: grafana/grafana:13.2.3
  restart: unless-stopped
  environment:
    GF_SECURITY_ADMIN_USER: ${GF_ADMIN_USER:-admin}
    GF_SECURITY_ADMIN_PASSWORD: ${GF_ADMIN_PASSWORD:-admin}
    GF_AUTH_ANONYMOUS_ENABLED: "false"
  healthcheck:
    test: ["CMD-SHELL", "wget -qO- localhost:3000/api/health || exit 1"]
    interval: 5s
    timeout: 3s
    retries: 30

services:
  grafana-dev:
    <<: *grafana
    container_name: grafana-dev
    ports: ["3000:3000"]
    volumes: ["grafana-dev-data:/var/lib/grafana"]

  grafana-prod:
    <<: *grafana
    container_name: grafana-prod
    ports: ["3001:3000"]
    volumes: ["grafana-prod-data:/var/lib/grafana"]

volumes:
  grafana-dev-data:
  grafana-prod-data:
```

- [ ] **Step 3: Start and verify**

Run: `cp -n .env.example .env; docker compose up -d && docker compose ps`
Then: `curl -s -u admin:admin localhost:3000/apis/provisioning.grafana.app/v0alpha1/namespaces/default/repositories | jq -r .kind` and same for `3001`.
Expected: both containers `healthy`; both curls print `RepositoryList`.

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: docker compose with dev and prod Grafana"
```

---

### Task 3: Repository templates and setup script

**Files:**
- Create: `repos/dev.yaml`, `repos/prod.yaml`, `scripts/lib.sh`, `scripts/setup.sh`

**Interfaces:**
- Consumes: env vars from Task 1, endpoints from Task 2.
- Produces: `scripts/lib.sh` functions — `load_env` (sources `.env`, exits 1 if `GITHUB_TOKEN` empty), `wait_healthy <base_url>` (polls `/api/health` up to 90s, exits 1 on timeout), `api <method> <base_url> <path> [body_file]` (curl with admin creds, prints body, returns non-zero on HTTP ≥ 400). Repository names: `poc-dev` on dev, `poc-prod` on prod. `REPO_API=/apis/provisioning.grafana.app/v0alpha1/namespaces/default/repositories`.

- [ ] **Step 1: Write `repos/dev.yaml`**

```yaml
apiVersion: provisioning.grafana.app/v0alpha1
kind: Repository
metadata:
  name: poc-dev
spec:
  title: Git Sync POC (dev)
  type: github
  github:
    url: ${GITHUB_REPO_URL}
    branch: dev
    path: grafana/
  sync:
    enabled: true
    intervalSeconds: 30
    target: folder
  workflows:
    - write
secure:
  token:
    create: ${GITHUB_TOKEN}
```

- [ ] **Step 2: Write `repos/prod.yaml`**

```yaml
apiVersion: provisioning.grafana.app/v0alpha1
kind: Repository
metadata:
  name: poc-prod
spec:
  title: Git Sync POC (prod)
  type: github
  github:
    url: ${GITHUB_REPO_URL}
    branch: main
    path: grafana/
  sync:
    enabled: true
    intervalSeconds: 30
    target: folder
  workflows: []
secure:
  token:
    create: ${GITHUB_TOKEN}
```

- [ ] **Step 3: Write `scripts/lib.sh`**

```bash
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
```

- [ ] **Step 4: Write the failing check for missing token**

Run: `mkdir -p scripts && GITHUB_TOKEN= bash -c 'source scripts/lib.sh; ROOT=$(mktemp -d); echo "GITHUB_TOKEN=" > $ROOT/.env; load_env'; echo "exit=$?"`
Expected: `ERROR: GITHUB_TOKEN is empty in .env`, `exit=1`.

- [ ] **Step 5: Write `scripts/setup.sh`**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
load_env
command -v envsubst >/dev/null || die "envsubst not found (brew install gettext)"
command -v jq >/dev/null || die "jq not found (brew install jq)"

apply_repo() {
  local base="$1" name="$2" tmpl="$3" rendered
  rendered="$(mktemp)"
  envsubst '${GITHUB_REPO_URL} ${GITHUB_TOKEN}' < "$tmpl" > "$rendered"

  wait_healthy "$base"
  if api GET "$base" "$REPO_API/$name" >/dev/null 2>&1; then
    echo "→ $name exists on $base, updating"
    api PUT "$base" "$REPO_API/$name" "$rendered" >/dev/null || { rm -f "$rendered"; die "update of $name failed"; }
  else
    echo "→ creating $name on $base"
    api POST "$base" "$REPO_API" "$rendered" >/dev/null || { rm -f "$rendered"; die "create of $name failed"; }
  fi
  rm -f "$rendered"

  echo "→ testing connection for $name"
  local result
  result="$(api POST "$base" "$REPO_API/$name/test" || true)"
  if [[ "$(jq -r '.success' <<<"$result")" != "true" ]]; then
    echo "$result" | jq . >&2
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
```

Run: `chmod +x scripts/*.sh`

- [ ] **Step 6: Run setup (needs real token in `.env`)**

Run: `./scripts/setup.sh`
Expected: create + `ok` for both repos, ends with `dev=success prod=success`.
If the status JSON shape differs (e.g. state field not at `.status.sync.state`), inspect `api GET $DEV_URL $REPO_API/poc-dev/status | jq .status` and fix the jq path — do not loosen the check.

- [ ] **Step 7: Verify idempotency**

Run: `./scripts/setup.sh` again.
Expected: `exists ... updating` for both, still ends in `success`.

- [ ] **Step 8: Verify seeded dashboard on both instances**

Run: `for p in 3000 3001; do curl -s -u admin:admin "localhost:$p/api/search?query=Sample" | jq -r '.[].title'; done`
Expected: `Sample Dashboard` printed twice.

- [ ] **Step 9: Commit**

```bash
git add repos scripts
git commit -m "feat: Repository templates and idempotent setup script"
```

---

### Task 4: End-to-end promotion script

**Files:**
- Create: `scripts/e2e.sh`

**Interfaces:**
- Consumes: `lib.sh` (`load_env`, `api`, `DEV_URL`, `PROD_URL`, `REPO_API`), repos `poc-dev`/`poc-prod` from Task 3, `gh` authenticated for `kmetto/grafana-sync-poc`.
- Produces: one-command proof of the full flow; exit 0 only if every assertion passes.

- [ ] **Step 1: Write `scripts/e2e.sh`**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
load_env
GH_REPO="${GITHUB_REPO_URL#https://github.com/}"
STAMP="$(date +%s)"
UID_="e2e-$STAMP"
FILE="e2e-$STAMP.json"
body="$(mktemp)"
cat > "$body" <<JSON
{"uid":"$UID_","title":"E2E $STAMP","schemaVersion":41,"panels":[]}
JSON

echo "1. prod must reject writes (read-only)"
if curl -sf -u "$GF_ADMIN_USER:$GF_ADMIN_PASSWORD" -X POST -H 'Content-Type: application/json' \
     --data-binary "@$body" "$PROD_URL$REPO_API/poc-prod/files/$FILE?message=should-fail" >/dev/null; then
  die "prod accepted a write — it must be read-only"
fi
echo "   ok"

echo "2. commit dashboard via dev Grafana (same API the UI uses)"
curl -sf -u "$GF_ADMIN_USER:$GF_ADMIN_PASSWORD" -X POST -H 'Content-Type: application/json' \
  --data-binary "@$body" "$DEV_URL$REPO_API/poc-dev/files/$FILE?ref=dev&message=e2e:%20add%20$FILE" >/dev/null \
  || die "dev write failed"
gh api "repos/$GH_REPO/contents/grafana/$FILE?ref=dev" >/dev/null || die "file not on branch dev"
echo "   ok: grafana/$FILE on dev"

echo "3. prod must NOT have it before merge"
sleep 35
[[ "$(curl -s -u "$GF_ADMIN_USER:$GF_ADMIN_PASSWORD" "$PROD_URL/api/dashboards/uid/$UID_" | jq -r '.dashboard.uid // empty')" == "" ]] \
  || die "dashboard reached prod before merge"
echo "   ok"

echo "4. PR dev → main and merge"
url="$(gh pr create -R "$GH_REPO" --base main --head dev --title "e2e: promote $FILE" --body "Automated POC check")"
gh pr merge -R "$GH_REPO" "$url" --merge
echo "   merged $url"

echo "5. prod picks it up within 90s"
for _ in $(seq 1 45); do
  got="$(curl -s -u "$GF_ADMIN_USER:$GF_ADMIN_PASSWORD" "$PROD_URL/api/dashboards/uid/$UID_" | jq -r '.dashboard.uid // empty')"
  [[ "$got" == "$UID_" ]] && { echo "   ok: $UID_ in prod"; rm -f "$body"; exit 0; }
  sleep 2
done
die "dashboard $UID_ did not appear in prod"
```

Run: `chmod +x scripts/e2e.sh`

- [ ] **Step 2: Run it**

Run: `./scripts/e2e.sh`
Expected: steps 1–5 each print `ok`, exit 0.
If step 1 fails because prod returns 2xx, the read-only config is wrong — fix `repos/prod.yaml`, do not delete the assertion.

- [ ] **Step 3: Sync local `main`**

Run: `git pull --rebase origin main`
Expected: local unpushed commits (Tasks 2–4) are replayed on top of the merge commit; no conflicts (Grafana only touches `grafana/`).

- [ ] **Step 4: Commit**

```bash
git add scripts/e2e.sh
git commit -m "test: end-to-end dev → PR → prod promotion script"
```

---

### Task 5: README and push

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`**

````markdown
# Grafana Git Sync POC

Two Grafana instances synced with this repo via [Git Sync](https://grafana.com/docs/grafana/latest/as-code/observability-as-code/git-sync/):

| Instance | URL | Branch | Mode |
|---|---|---|---|
| dev | http://localhost:3000 | `dev` | read-write — UI saves are committed |
| prod | http://localhost:3001 | `main` | read-only |

Promotion to prod = PR `dev → main`. Prod polls every 30s.

## Run

1. Create a fine-grained GitHub PAT for this repo: Contents RW, Pull requests RW, Metadata R, Administration R, Webhooks RW.
2. `cp .env.example .env` and set `GITHUB_TOKEN`.
3. `docker compose up -d`
4. `./scripts/setup.sh`

Login: `admin` / `admin`.

## Demo (manual)

1. In dev, open folder **Git Sync POC (dev)**, create a dashboard, Save → it is committed to `dev`.
2. `gh pr create --base main --head dev --fill && gh pr merge --merge`
3. Within ~30s the dashboard shows up in prod under **Git Sync POC (prod)**; it cannot be saved there.

## Demo (automated)

`./scripts/e2e.sh` — commits a dashboard via dev, checks prod is read-only and doesn't see it before merge, opens and merges a PR, asserts it lands in prod.

Dashboards live in `grafana/`. Everything else in the repo is ignored by Grafana.
````

- [ ] **Step 2: Commit and push**

```bash
git add README.md
git commit -m "docs: README for Git Sync POC"
git push origin main
git push origin main:dev
```

Expected: both pushes succeed; `dev` fast-forwards to `main`, so the next PR `dev → main` contains only Grafana-made changes.
