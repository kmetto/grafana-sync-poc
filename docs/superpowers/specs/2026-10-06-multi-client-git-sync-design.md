# Multi-client Git Sync — Design

Date: 2026-10-06
Supersedes the single dev/prod pair from `2026-10-06-grafana-git-sync-poc-design.md`.

## Goal

One shared dev Grafana where we build dashboards for several clients. Each client has its own
GitHub repository and its own (prod) Grafana instance. In dev, each client is a folder synced
with that client's repo; each client's prod Grafana reads only its own repo, read-only.

## Decisions

| Topic | Decision |
|---|---|
| Clients | `client-1`, `client-2`, `client-3` |
| Client repos | `kmetto/grafana-client-1..3`, public, created with `gh`, branches `main` + `dev`, dashboards under `grafana/` |
| Infra repo | `kmetto/grafana-sync-poc` holds only code (Terraform, compose, scripts, docs); its `grafana/` folder is removed |
| Dev instance | existing `grafana-dev` on :3000; one Repository per client: `client-N-dev`, branch `dev`, `workflows: [write]`, folder title `Client N` |
| Client prod instances | POC: local containers `grafana-client-1..3` on :3001..:3003; each has one Repository `client-N-prod`, branch `main`, `workflows: []` |
| Promotion | per client: PR `dev → main` in that client's repo |
| Sync | polling, `intervalSeconds: 30`, `target: folder`, `path: grafana/` |
| Auth | one GitHub fine-grained PAT with access to all client repos (POC); Grafana admin `admin`/`admin` |
| Terraform layout | two root modules sharing `terraform/modules/git-sync-repo`: `terraform/dev` (one provider, `for_each` over clients) and `terraform/client-prod` (one client per run, selected by Terraform workspace = client id) |
| Client list | single source of truth `clients.json` at repo root, read by both root modules and by scripts |
| State | local; `terraform/dev` has one state, `terraform/client-prod` one state per workspace |

## Removed

- Repositories `poc-dev` (dev) and `poc-prod` (prod) — destroyed via Terraform; folder "Git Sync POC (dev)" and its 3 dashboards disappear from dev (they remain in `grafana-sync-poc` git history).
- Container `grafana-prod` and volume `grafana-prod-data`.
- Manual empty folders `client 2` (`fg0eh3mmkfapsa`) and `client 3` (`cg0eh4fw63h8gb`) in dev.
- `terraform/main.tf`, `providers.tf` single-pair config (replaced by the two root modules).

## Architecture

```
dev Grafana :3000                       GitHub                               client prod
 folder "Client 1" ─ client-1-dev ─▶ grafana-client-1: dev ─PR─▶ main ─▶ grafana-client-1 :3001 (RO)
 folder "Client 2" ─ client-2-dev ─▶ grafana-client-2: dev ─PR─▶ main ─▶ grafana-client-2 :3002 (RO)
 folder "Client 3" ─ client-3-dev ─▶ grafana-client-3: dev ─PR─▶ main ─▶ grafana-client-3 :3003 (RO)
```

`clients.json`:

```json
{
  "client-1": { "title": "Client 1", "repo": "kmetto/grafana-client-1", "prod_url": "http://localhost:3001" },
  "client-2": { "title": "Client 2", "repo": "kmetto/grafana-client-2", "prod_url": "http://localhost:3002" },
  "client-3": { "title": "Client 3", "repo": "kmetto/grafana-client-3", "prod_url": "http://localhost:3003" }
}
```

- `terraform/dev`: `module "client" { for_each = local.clients ... }` with `uid = "${each.key}-dev"`, `branch = "dev"`, `workflows = ["write"]`.
- `terraform/client-prod`: `local.client = local.clients[terraform.workspace]`; provider URL = `local.client.prod_url`; one module call with `uid = "${terraform.workspace}-prod"`, `branch = "main"`, `workflows = []`. Running in the `default` workspace or an unknown workspace fails with a clear error.
- `scripts/tf.sh` takes the root as first argument: `tf.sh dev apply`, `tf.sh client-prod <client> apply` (selects/creates the workspace).

Adding a client = add an entry to `clients.json`, create its repo, add a compose service, `tf.sh dev apply`, `tf.sh client-prod client-N apply`.

## Scripts

- `scripts/verify.sh [client]` — for each client (or one): `/test` and sync `success` for `client-N-dev` on dev and `client-N-prod` on its prod.
- `scripts/e2e.sh <client>` — the existing 5-step flow against that client's repo/prod, plus an isolation check: the dashboard committed in client X's dev folder is absent from every other client's repo `dev` branch and every other client's prod.
- `scripts/bootstrap-repos.sh` — creates missing client repos from `clients.json` with `gh`, seeds `grafana/sample-dashboard.json` on `main`, creates `dev` from `main`. Idempotent.

## Error handling

- Unknown or `default` workspace in `client-prod` → Terraform `precondition`/validation error naming valid clients.
- `verify.sh` / `e2e.sh` with an unknown client → non-zero exit listing valid clients.
- `bootstrap-repos.sh` skips repos that already exist; never deletes or force-pushes.

## Verification (success criteria)

1. Three client repos exist with `main` and `dev`, each containing `grafana/sample-dashboard.json`.
2. `tf.sh dev apply` then `tf.sh dev plan` → no changes; dev shows folders Client 1..3 and no "Git Sync POC (dev)", "client 2", "client 3".
3. For each client: `tf.sh client-prod client-N apply` then `plan` → no changes.
4. `verify.sh` → all 6 repositories `ok` and `success`.
5. `e2e.sh client-2` passes, including isolation (nothing appears for client-1/client-3).
6. GitHub token absent from every state file.

## Out of scope

Creating repos via the Terraform `github` provider, remote state, webhooks, GitHub App / Connection per client (documented in README as next step), real client-hosted Grafana instances.
