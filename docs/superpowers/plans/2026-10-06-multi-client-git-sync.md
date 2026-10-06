# Multi-client Git Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One shared dev Grafana with a folder per client, each synced to that client's GitHub repo; one read-only prod Grafana per client reading only its own repo.

**Architecture:** `clients.json` is the single source of truth. Terraform has two root modules sharing `terraform/modules/git-sync-repo`: `terraform/dev` (`for_each` over clients, one provider) and `terraform/client-prod` (one client per run, selected by Terraform workspace). Bash scripts bootstrap repos, verify sync, and run an e2e + isolation check per client.

**Tech Stack:** Docker Compose, `grafana/grafana:13.2.3`, Terraform 1.16 + `grafana/grafana` provider 4.47, bash + curl + jq, `gh` CLI.

**Spec:** `docs/superpowers/specs/2026-10-06-multi-client-git-sync-design.md`

## Global Constraints

- Clients: `client-1`, `client-2`, `client-3`; repos `kmetto/grafana-client-1..3` (public), branches `main` + `dev`, dashboards under `grafana/`.
- Dev Grafana `http://localhost:3000`; client prod Grafanas `http://localhost:3001..3003`, containers `grafana-client-1..3`.
- Dev Repository per client: uid `client-N-dev`, title `Client N`, branch `dev`, `workflows = ["write"]`.
- Prod Repository per client: uid `client-N-prod`, title `Client N`, branch `main`, `workflows = []`.
- Sync: `enabled = true`, `interval_seconds = 30`, `target = "folder"`, `path = "grafana/"`.
- Grafana admin `admin`/`admin` from `.env` (`GF_ADMIN_USER`, `GF_ADMIN_PASSWORD`); GitHub PAT from `.env` `GITHUB_TOKEN`, covering all client repos.
- The GitHub token must never appear in any committed file, any state file, or any printed output.
- Dashboard uids are global per Grafana instance: every dashboard seeded into a client repo uses uid `<client-id>-<name>`.
- Never force-push, never delete branches, never rewrite history.

## Review Focus

1. Same dashboard uid in two client repos → collision in the shared dev Grafana. Seeds must use `<client-id>-sample` (asserted in Task 2 Step 4).
2. `tf.sh client-prod` with an unknown client or in workspace `default` → clear error listing valid clients, no apply (tested in Task 5 Step 5).
3. Dashboard committed in client-2's dev folder must not appear in client-1/client-3 repos or prods (tested in Task 6 e2e step 6).
4. `bootstrap-repos.sh` rerun on existing repos → skips, no error, no force-push (tested in Task 2 Step 6).
5. `verify.sh unknown-client` → non-zero exit listing valid clients (tested in Task 6 Step 3).

---

## File Structure

| File | Responsibility |
|---|---|
| `clients.json` | client id → title, repo, prod_url |
| `scripts/lib.sh` | shared helpers + client lookup (`clients`, `client_field`, `require_client`) |
| `scripts/bootstrap-repos.sh` | create/seed client repos with `gh` (idempotent) |
| `scripts/tf.sh` | run terraform in `terraform/dev` or `terraform/client-prod` (workspace = client) with creds from `.env` |
| `terraform/modules/git-sync-repo/` | unchanged module: one Git Sync Repository |
| `terraform/dev/` | root: dev Grafana, one Repository per client |
| `terraform/client-prod/` | root: one client's prod Grafana, one Repository |
| `scripts/verify.sh` | `/test` + sync status for all or one client |
| `scripts/e2e.sh` | per-client promotion flow + isolation check |
| `docker-compose.yml` | `grafana-dev` + `grafana-client-1..3` |

---

### Task 1: Tear down the single dev/prod pair

**Files:**
- Delete: `terraform/main.tf`, `terraform/providers.tf`, `terraform/variables.tf`, `terraform/versions.tf`, `terraform/.terraform.lock.hcl`, `grafana/` (whole dir)
- Modify: `docker-compose.yml` (remove `grafana-prod` service and `grafana-prod-data` volume)

**Interfaces:**
- Produces: dev Grafana with no Repositories and no folders `poc-dev`, `fg0eh3mmkfapsa`, `cg0eh4fw63h8gb`; no `grafana-prod` container/volume; `terraform/` contains only `modules/git-sync-repo/`.

- [ ] **Step 1: Destroy both Repositories with the current Terraform config**

Run: `./scripts/tf.sh destroy -auto-approve -no-color | tail -3`
Expected: `Destroy complete! Resources: 2 destroyed.`

- [ ] **Step 2: Verify they are gone**

Run:
```bash
for p in 3000 3001; do curl -s -u admin:admin localhost:$p/apis/provisioning.grafana.app/v0alpha1/namespaces/default/repositories | jq '.items | length'; done
curl -s -o /dev/null -w '%{http_code}\n' -u admin:admin localhost:3000/api/folders/poc-dev
```
Expected: `0`, `0`, then `404` (Grafana removes the managed folder; if it is still there after 30s, delete it with `curl -X DELETE -u admin:admin localhost:3000/api/folders/poc-dev`).

- [ ] **Step 3: Delete the manual empty folders**

```bash
for f in fg0eh3mmkfapsa cg0eh4fw63h8gb; do curl -s -X DELETE -u admin:admin localhost:3000/api/folders/$f | jq -r .message; done
curl -s -u admin:admin localhost:3000/api/folders | jq -r '.[].title'
```
Expected: two deletion messages; final listing prints nothing.

- [ ] **Step 4: Remove the prod container, volume and compose service**

In `docker-compose.yml` delete the whole `grafana-prod:` service block and the `grafana-prod-data:` line under `volumes:`. Then:
```bash
docker compose rm -sf grafana-prod
docker volume ls --format '{{.Name}}' | grep grafana-prod-data | xargs -r docker volume rm
docker compose config --services
```
Expected: last command prints only `grafana-dev`.

- [ ] **Step 5: Remove the old root module, state and the infra repo's dashboards**

```bash
git rm -q terraform/main.tf terraform/providers.tf terraform/variables.tf terraform/versions.tf terraform/.terraform.lock.hcl
git rm -rq grafana
rm -rf terraform/.terraform terraform/terraform.tfstate terraform/terraform.tfstate.backup
ls terraform
```
Expected: `ls terraform` prints only `modules`.

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yml
git commit -m "chore: tear down single dev/prod Git Sync pair"
```

---

### Task 2: Client registry and repo bootstrap

**Files:**
- Create: `clients.json`, `scripts/bootstrap-repos.sh`
- Modify: `scripts/lib.sh`

**Interfaces:**
- Produces in `scripts/lib.sh`: `CLIENTS_FILE`, `clients` (prints client ids, one per line, sorted), `client_field <id> <field>` (prints value or empty), `require_client <id>` (dies with `unknown client '<id>' — valid: client-1,client-2,client-3`). `load_env` no longer requires `GITHUB_REPO_URL`. `PROD_URL` removed; `DEV_URL` stays.
- Produces on GitHub: `kmetto/grafana-client-1..3` with `main` and `dev`, each containing `grafana/sample-dashboard.json` with uid `<client-id>-sample`.

- [ ] **Step 1: Write `clients.json`**

```json
{
  "client-1": { "title": "Client 1", "repo": "kmetto/grafana-client-1", "prod_url": "http://localhost:3001" },
  "client-2": { "title": "Client 2", "repo": "kmetto/grafana-client-2", "prod_url": "http://localhost:3002" },
  "client-3": { "title": "Client 3", "repo": "kmetto/grafana-client-3", "prod_url": "http://localhost:3003" }
}
```

- [ ] **Step 2: Update `scripts/lib.sh`**

Replace lines 5-6 (`DEV_URL`/`PROD_URL`) with:
```bash
DEV_URL="http://localhost:3000"
CLIENTS_FILE="$ROOT/clients.json"
```
Delete the line `[[ -n "${GITHUB_REPO_URL:-}" ]] || die "GITHUB_REPO_URL is empty in .env"` from `load_env`. Append:
```bash
# clients — client ids from clients.json, one per line
clients() { jq -r 'keys[]' "$CLIENTS_FILE"; }

# client_field ID FIELD — prints the field (title|repo|prod_url) or nothing
client_field() { jq -r --arg c "$1" --arg f "$2" '.[$c][$f] // empty' "$CLIENTS_FILE"; }

require_client() {
  [[ -n "$(client_field "${1:-}" repo)" ]] || die "unknown client '${1:-}' — valid: $(clients | paste -sd, -)"
}
```

- [ ] **Step 3: Test the helpers**

Run:
```bash
bash -c 'source scripts/lib.sh; clients; client_field client-2 prod_url; require_client client-3 && echo ok3; require_client nope'; echo "exit=$?"
```
Expected: `client-1`, `client-2`, `client-3`, `http://localhost:3002`, `ok3`, `ERROR: unknown client 'nope' — valid: client-1,client-2,client-3`, `exit=1`.

- [ ] **Step 4: Write `scripts/bootstrap-repos.sh`**

```bash
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
```
Run: `chmod +x scripts/bootstrap-repos.sh && bash -n scripts/bootstrap-repos.sh`

- [ ] **Step 5: Run it**

Run: `./scripts/bootstrap-repos.sh`
Then verify:
```bash
for id in client-1 client-2 client-3; do
  r=kmetto/grafana-$id
  echo "$r: $(gh api repos/$r/branches --jq '[.[].name]|sort|join(",")') uid=$(gh api "repos/$r/contents/grafana/sample-dashboard.json?ref=dev" --jq .content | base64 -d | jq -r .uid)"
done
```
Expected: `kmetto/grafana-client-N: dev,main uid=client-N-sample` for N = 1..3.

- [ ] **Step 6: Verify idempotency**

Run: `./scripts/bootstrap-repos.sh`
Expected: for each repo `exists`, `main exists`, `dev exists`; exit 0.

- [ ] **Step 7: Commit**

```bash
git add clients.json scripts/lib.sh scripts/bootstrap-repos.sh
git commit -m "feat: client registry and repo bootstrap script"
```

**CHECKPOINT (controller):** the user must add `kmetto/grafana-client-1..3` to their fine-grained PAT. Verify without printing the token:
```bash
set -a; . ./.env; set +a
for id in client-1 client-2 client-3; do curl -s -o /dev/null -w "$id %{http_code}\n" -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/repos/kmetto/grafana-$id/contents/grafana; done
```
Expected: `200` for all three before starting Task 4.

---

### Task 3: Client prod containers

**Files:**
- Modify: `docker-compose.yml`

**Interfaces:**
- Produces: containers `grafana-client-1` (:3001), `grafana-client-2` (:3002), `grafana-client-3` (:3003), healthy, admin creds from `.env`.

- [ ] **Step 1: Add services**

Under `services:` (after `grafana-dev`) add:
```yaml
  grafana-client-1:
    <<: *grafana
    container_name: grafana-client-1
    ports: ["3001:3000"]
    volumes: ["grafana-client-1-data:/var/lib/grafana"]

  grafana-client-2:
    <<: *grafana
    container_name: grafana-client-2
    ports: ["3002:3000"]
    volumes: ["grafana-client-2-data:/var/lib/grafana"]

  grafana-client-3:
    <<: *grafana
    container_name: grafana-client-3
    ports: ["3003:3000"]
    volumes: ["grafana-client-3-data:/var/lib/grafana"]
```
Under `volumes:` add `grafana-client-1-data:`, `grafana-client-2-data:`, `grafana-client-3-data:`.

- [ ] **Step 2: Start and verify**

Run: `docker compose up -d && docker compose ps --format '{{.Name}} {{.Status}}'`
Wait until all four are `(healthy)`, then:
```bash
for p in 3000 3001 3002 3003; do echo "$p $(curl -s -o /dev/null -w '%{http_code}' -u admin:admin localhost:$p/api/org)"; done
```
Expected: four lines ending in `200`.

- [ ] **Step 3: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: per-client prod Grafana containers"
```

---

### Task 4: Terraform root for dev + tf.sh

**Files:**
- Create: `terraform/dev/versions.tf`, `terraform/dev/variables.tf`, `terraform/dev/main.tf`
- Modify: `scripts/tf.sh` (rewrite)

**Interfaces:**
- Consumes: `clients.json`, module `terraform/modules/git-sync-repo` (inputs `uid`, `title`, `repo_url`, `branch`, `path`, `workflows`, `interval_seconds`, `github_token`, `token_version`), `lib.sh` (`load_env`, `require_client`, `ROOT`).
- Produces: `scripts/tf.sh dev <terraform args…>` and `scripts/tf.sh client-prod <client-id> <terraform args…>` (the latter used in Task 5). Module instances `module.client["client-N"]` in dev state.

- [ ] **Step 1: Write `terraform/dev/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.11" # write-only secrets (secure.token) need 1.11+

  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = ">= 4.28.1"
    }
  }
}
```

- [ ] **Step 2: Write `terraform/dev/variables.tf`**

```hcl
variable "github_token" {
  description = "GitHub PAT with access to all client repos. Write-only: never stored in state."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "grafana_url" {
  type    = string
  default = "http://localhost:3000"
}

variable "grafana_auth" {
  description = "Grafana admin credentials as user:password, or a service account token."
  type        = string
  sensitive   = true
  default     = "admin:admin"
}
```

- [ ] **Step 3: Write `terraform/dev/main.tf`**

```hcl
locals {
  clients = jsondecode(file("${path.module}/../../clients.json"))
}

provider "grafana" {
  url  = var.grafana_url
  auth = var.grafana_auth
}

# One folder per client in the shared dev Grafana; UI saves are committed to the client's `dev` branch.
module "client" {
  source   = "../modules/git-sync-repo"
  for_each = local.clients

  uid          = "${each.key}-dev"
  title        = each.value.title
  repo_url     = "https://github.com/${each.value.repo}"
  branch       = "dev"
  workflows    = ["write"]
  github_token = var.github_token
}
```

- [ ] **Step 4: Rewrite `scripts/tf.sh`**

```bash
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
```

- [ ] **Step 5: Validate and apply**

Run:
```bash
./scripts/tf.sh dev validate -no-color
./scripts/tf.sh dev apply -auto-approve -no-color | tail -2
./scripts/tf.sh dev plan -detailed-exitcode -no-color >/dev/null; echo "re-plan exit=$?"
```
Expected: `Success! The configuration is valid.`; `Apply complete! Resources: 3 added, 0 changed, 0 destroyed.`; `re-plan exit=0`.
If re-plan shows a diff, inspect it and pin the offending attribute in the module (as was done for `generate_dashboard_previews`) — do not ignore it.

- [ ] **Step 6: Verify folders in dev**

Run:
```bash
curl -s -u admin:admin localhost:3000/api/folders | jq -r '.[] | "\(.uid) \(.title)"' | sort
curl -s -u admin:admin 'localhost:3000/api/search?type=dash-db' | jq -r '.[].uid' | sort
```
Expected (allow up to 30s for first sync): folders `client-1-dev Client 1`, `client-2-dev Client 2`, `client-3-dev Client 3`; dashboards `client-1-sample`, `client-2-sample`, `client-3-sample`.

- [ ] **Step 7: Commit**

```bash
git add terraform/dev/versions.tf terraform/dev/variables.tf terraform/dev/main.tf terraform/dev/.terraform.lock.hcl scripts/tf.sh
git commit -m "feat: terraform root for dev — one Git Sync repository per client"
```

---

### Task 5: Terraform root for client prod

**Files:**
- Create: `terraform/client-prod/versions.tf`, `terraform/client-prod/variables.tf`, `terraform/client-prod/main.tf`

**Interfaces:**
- Consumes: `clients.json`, module `git-sync-repo`, `tf.sh client-prod <client-id>` from Task 4.
- Produces: per-workspace state `terraform/client-prod/terraform.tfstate.d/<client-id>/terraform.tfstate`; Repository `<client-id>-prod` on that client's Grafana.

- [ ] **Step 1: Write `terraform/client-prod/versions.tf`**

Identical content to `terraform/dev/versions.tf` (Task 4 Step 1):
```hcl
terraform {
  required_version = ">= 1.11" # write-only secrets (secure.token) need 1.11+

  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = ">= 4.28.1"
    }
  }
}
```

- [ ] **Step 2: Write `terraform/client-prod/variables.tf`**

```hcl
variable "github_token" {
  description = "GitHub PAT with access to the client repo. Write-only: never stored in state."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "grafana_auth" {
  description = "Grafana admin credentials as user:password, or a service account token."
  type        = string
  sensitive   = true
  default     = "admin:admin"
}
```

- [ ] **Step 3: Write `terraform/client-prod/main.tf`**

```hcl
# One run = one client. The Terraform workspace name is the client id (scripts/tf.sh selects it).
locals {
  clients   = jsondecode(file("${path.module}/../../clients.json"))
  client_id = terraform.workspace
  client    = lookup(local.clients, local.client_id, null)
}

provider "grafana" {
  url  = try(local.client.prod_url, "http://invalid.invalid")
  auth = var.grafana_auth
}

resource "terraform_data" "workspace_guard" {
  lifecycle {
    precondition {
      condition     = local.client != null
      error_message = "Workspace '${local.client_id}' is not a client in clients.json. Valid: ${join(", ", keys(local.clients))}. Use scripts/tf.sh client-prod <client-id> ..."
    }
  }
}

# Read-only: prod follows `main`; changes arrive only via merged PRs dev -> main in the client's repo.
module "client" {
  source     = "../modules/git-sync-repo"
  depends_on = [terraform_data.workspace_guard]

  uid          = "${local.client_id}-prod"
  title        = try(local.client.title, local.client_id)
  repo_url     = "https://github.com/${try(local.client.repo, "invalid/invalid")}"
  branch       = "main"
  workflows    = []
  github_token = var.github_token
}
```

- [ ] **Step 4: Apply for each client**

Run:
```bash
for c in client-1 client-2 client-3; do
  ./scripts/tf.sh client-prod $c apply -auto-approve -no-color | tail -1
  ./scripts/tf.sh client-prod $c plan -detailed-exitcode -no-color >/dev/null; echo "$c re-plan exit=$?"
done
```
Expected per client: `Apply complete! Resources: 2 added, 0 changed, 0 destroyed.` (guard + repository) and `re-plan exit=0`.

- [ ] **Step 5: Verify the guard (Review Focus 2)**

Run:
```bash
./scripts/tf.sh client-prod nope plan -no-color; echo "exit=$?"
terraform -chdir=terraform/client-prod workspace select default >/dev/null
TF_VAR_github_token=x terraform -chdir=terraform/client-prod plan -no-color 2>&1 | grep -E "not a client|Error" | head -2; echo "default-ws exit=${PIPESTATUS[0]}"
```
Expected: first → `ERROR: unknown client 'nope' — valid: client-1,client-2,client-3`, `exit=1`; second → output contains `Workspace 'default' is not a client in clients.json`, non-zero exit.

- [ ] **Step 6: Verify each prod sees only its own dashboard**

Run:
```bash
for p in 3001 3002 3003; do echo "$p: $(curl -s -u admin:admin "localhost:$p/api/search?type=dash-db" | jq -r '[.[].uid]|join(",")')"; done
```
Expected (allow 30s): `3001: client-1-sample`, `3002: client-2-sample`, `3003: client-3-sample`.

- [ ] **Step 7: Commit**

```bash
git add terraform/client-prod/versions.tf terraform/client-prod/variables.tf terraform/client-prod/main.tf terraform/client-prod/.terraform.lock.hcl
git commit -m "feat: terraform root for client prod (workspace per client)"
```

---

### Task 6: Multi-client verify and e2e with isolation check

**Files:**
- Modify: `scripts/verify.sh` (rewrite), `scripts/e2e.sh` (rewrite)

**Interfaces:**
- Consumes: `lib.sh` (`load_env`, `api`, `wait_healthy`, `clients`, `client_field`, `require_client`, `DEV_URL`, `REPO_API`, `die`).
- Produces: `scripts/verify.sh [client-id]`, `scripts/e2e.sh <client-id>`.

- [ ] **Step 1: Rewrite `scripts/verify.sh`**

```bash
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
```

- [ ] **Step 2: Run verify**

Run: `./scripts/verify.sh; echo "exit=$?"` then `./scripts/verify.sh client-2; echo "exit=$?"`
Expected: 6 × `ok`, `all 6 repositories synced`, `exit=0`; then 2 × `ok`, `all 2 repositories synced`, `exit=0`.

- [ ] **Step 3: Verify unknown client (Review Focus 5)**

Run: `./scripts/verify.sh nope; echo "exit=$?"`
Expected: `ERROR: unknown client 'nope' — valid: client-1,client-2,client-3`, `exit=1`.

- [ ] **Step 4: Rewrite `scripts/e2e.sh`**

```bash
#!/usr/bin/env bash
# Usage: e2e.sh <client-id> — dev folder → client repo `dev` → PR → `main` → client prod, plus isolation from other clients.
source "$(dirname "$0")/lib.sh"
load_env
CLIENT="${1:-}"; require_client "$CLIENT"
GH_REPO="$(client_field "$CLIENT" repo)"
PROD_URL="$(client_field "$CLIENT" prod_url)"
DEV_REPO="$CLIENT-dev"; PROD_REPO="$CLIENT-prod"
STAMP="$(date +%s)"
UID_="$CLIENT-e2e-$STAMP"
FILE="e2e-$STAMP.json"

body="$(mktemp)"; resp="$(mktemp)"
trap 'rm -f "$body" "$resp"' EXIT
# Note: Grafana's file parser rejects a bare dashboard without "tags" ("unable to read bytes as a resource").
cat > "$body" <<JSON
{"uid":"$UID_","title":"E2E $CLIENT $STAMP","schemaVersion":41,"tags":["e2e"],"panels":[]}
JSON

# post_file BASE REPO QUERY — echoes HTTP status; response body goes to $resp
post_file() {
  curl -s -o "$resp" -w '%{http_code}' -u "$GF_ADMIN_USER:$GF_ADMIN_PASSWORD" -X POST \
    -H 'Content-Type: application/json' --data-binary "@$body" "$1$REPO_API/$2/files/$FILE?$3"
}
dash_uid_on() { curl -s -u "$GF_ADMIN_USER:$GF_ADMIN_PASSWORD" "$1/api/dashboards/uid/$UID_" | jq -r '.dashboard.uid // empty'; }

echo "1. $CLIENT prod must reject writes (read-only)"
code="$(post_file "$PROD_URL" "$PROD_REPO" "message=should-fail")"
[[ "$code" =~ ^2 ]] && die "prod accepted a write (HTTP $code) — it must be read-only"
echo "   ok: prod rejected write with HTTP $code: $(jq -r '.message // empty' "$resp" 2>/dev/null)"

echo "2. commit dashboard via $CLIENT's dev folder"
code="$(post_file "$DEV_URL" "$DEV_REPO" "ref=dev&message=e2e:%20add%20$FILE")"
[[ "$code" =~ ^2 ]] || die "dev write failed (HTTP $code): $(cat "$resp")"
gh api "repos/$GH_REPO/contents/grafana/$FILE?ref=dev" >/dev/null || die "file not on $GH_REPO dev"
echo "   ok: grafana/$FILE on $GH_REPO dev"

echo "3. $CLIENT prod must NOT have it before merge"
sleep 35
[[ -z "$(dash_uid_on "$PROD_URL")" ]] || die "dashboard reached prod before merge"
echo "   ok"

echo "4. PR dev -> main in $GH_REPO and merge"
url="$(gh pr create -R "$GH_REPO" --base main --head dev --title "e2e: promote $FILE" --body "Automated POC check")"
gh pr merge -R "$GH_REPO" "$url" --merge
echo "   merged $url"

echo "5. $CLIENT prod picks it up within 90s"
found=""
for _ in $(seq 1 45); do
  [[ "$(dash_uid_on "$PROD_URL")" == "$UID_" ]] && { found=1; break; }
  sleep 2
done
[[ -n "$found" ]] || die "dashboard $UID_ did not appear in $CLIENT prod"
echo "   ok: $UID_ in $CLIENT prod"

echo "6. other clients are isolated"
for other in $(clients); do
  [[ "$other" == "$CLIENT" ]] && continue
  orepo="$(client_field "$other" repo)"
  if gh api "repos/$orepo/contents/grafana/$FILE?ref=dev" >/dev/null 2>&1 \
     || gh api "repos/$orepo/contents/grafana/$FILE?ref=main" >/dev/null 2>&1; then
    die "$FILE leaked into $orepo"
  fi
  [[ -z "$(dash_uid_on "$(client_field "$other" prod_url)")" ]] || die "$UID_ leaked into $other prod"
  echo "   ok: not in $orepo or $other prod"
done
```

- [ ] **Step 5: Run e2e for client-2**

Run: `chmod +x scripts/e2e.sh scripts/verify.sh && ./scripts/e2e.sh client-2; echo "exit=$?"`
Expected: steps 1–5 `ok`, step 6 `ok` for client-1 and client-3, `exit=0`.
If step 1 returns 2xx, the prod config is wrong — fix `terraform/client-prod`, never delete the assertion.

- [ ] **Step 6: Commit**

```bash
git add scripts/verify.sh scripts/e2e.sh
git commit -m "feat: multi-client verify and e2e with isolation check"
```

---

### Task 7: Docs, env template, push

**Files:**
- Modify: `README.md` (rewrite), `.env.example`, `.gitignore`

- [ ] **Step 1: Update `.env.example`**

```dotenv
# GitHub fine-grained PAT with access to every client repo in clients.json
# Permissions: Contents RW, Pull requests RW, Metadata R, Administration R, Webhooks RW
GITHUB_TOKEN=
GF_ADMIN_USER=admin
GF_ADMIN_PASSWORD=admin
```

- [ ] **Step 2: Update `.gitignore`**

Replace the line `terraform/.terraform/` with `terraform/**/.terraform/` and add `terraform/**/terraform.tfstate.d/`.
Run: `git status --short --ignored terraform | grep -E 'tfstate|\.terraform/'`
Expected: every state file and `.terraform/` dir is listed as ignored (`!!`).

- [ ] **Step 3: Rewrite `README.md`**

````markdown
# Grafana Git Sync — multi-client POC

One shared **dev** Grafana where we build dashboards for several clients. Each client has its own GitHub repo and its own read-only **prod** Grafana.

```
dev Grafana :3000                       GitHub                               client prod
 folder "Client 1" ─ client-1-dev ─▶ grafana-client-1: dev ─PR─▶ main ─▶ grafana-client-1 :3001 (RO)
 folder "Client 2" ─ client-2-dev ─▶ grafana-client-2: dev ─PR─▶ main ─▶ grafana-client-2 :3002 (RO)
 folder "Client 3" ─ client-3-dev ─▶ grafana-client-3: dev ─PR─▶ main ─▶ grafana-client-3 :3003 (RO)
```

- Saving a dashboard in a client's folder in dev commits it to that client's repo, branch `dev`.
- Promotion = PR `dev → main` in the client's repo. The client's prod polls `main` every 30s.
- Clients are listed in `clients.json` (id → title, repo, prod URL). Scripts and Terraform read it.

## Run

1. `cp .env.example .env`, set `GITHUB_TOKEN` (fine-grained PAT covering all client repos: Contents RW, Pull requests RW, Metadata R, Administration R, Webhooks RW).
2. Install Terraform ≥ 1.11 (`brew install hashicorp/tap/terraform`) and `jq`; authenticate `gh`.
3. `./scripts/bootstrap-repos.sh` — creates missing client repos with `main`/`dev` and a sample dashboard.
4. `docker compose up -d`
5. `./scripts/tf.sh dev apply` — one Git Sync repository per client in dev
6. `for c in client-1 client-2 client-3; do ./scripts/tf.sh client-prod $c apply; done`
7. `./scripts/verify.sh` — every repository reaches GitHub and has synced

Login everywhere: `admin` / `admin`. If you change a password in the UI, update `.env` — otherwise Terraform/scripts get 401s and Grafana locks the login for 5 minutes after a few failures.

## Add a client

1. Add an entry to `clients.json`.
2. Add a `grafana-client-N` service + volume to `docker-compose.yml` (next free port), `docker compose up -d`.
3. `./scripts/bootstrap-repos.sh`, and give your PAT access to the new repo.
4. `./scripts/tf.sh dev apply` and `./scripts/tf.sh client-prod client-N apply`.

## Terraform layout

- `terraform/modules/git-sync-repo` — one Git Sync Repository (shared).
- `terraform/dev` — dev Grafana; `for_each` over `clients.json` → `client-N-dev`, branch `dev`, `workflows = ["write"]`.
- `terraform/client-prod` — one client's prod Grafana per run; the Terraform **workspace is the client id** (`tf.sh client-prod client-2 …` selects it), so each client has its own state. `client-N-prod`, branch `main`, `workflows = []` (read-only).
- Terraform can't `for_each` over providers, which is why prod is a separate root run per client.
- The GitHub token is a write-only attribute and never lands in state. State is local and gitignored.

## Checks

- `./scripts/verify.sh [client-id]` — `/test` + sync status.
- `./scripts/e2e.sh <client-id>` — commits a dashboard via that client's dev folder, checks prod is read-only and doesn't see it before merge, opens and merges a PR in the client repo, asserts it lands in that client's prod and nowhere else. Each run leaves one `grafana/e2e-<timestamp>.json` and one merged PR in the client repo.

## Gotchas

- **Dashboard uids are global per Grafana instance.** Two client repos containing the same uid collide in the shared dev Grafana. Dashboards created in the UI get random uids; copies between clients must get a new uid.
- Only dashboards inside a client's synced folder go to git. Git Sync creates its own folder per repository; it can't adopt an existing folder.

## Next steps for real clients

- Replace the shared PAT with a GitHub App: one `grafana_apps_provisioning_connection_v0alpha1` per Grafana, referenced from each repository's `spec.connection`.
- Remote state (S3 or Azure Blob) with one key per root/workspace.
````

- [ ] **Step 4: Commit and push the infra repo**

```bash
git add README.md .env.example .gitignore
git commit -m "docs: multi-client README and env template"
git push origin main
```
Expected: push succeeds (fast-forward).
