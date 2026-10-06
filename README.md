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
- Plain-language walkthrough (RU): docs/how-it-works.md

## Gotchas

- **Dashboard uids are global per Grafana instance.** Two client repos containing the same uid collide in the shared dev Grafana. Dashboards created in the UI get random uids; copies between clients must get a new uid.
- Only dashboards inside a client's synced folder go to git. Git Sync creates its own folder per repository; it can't adopt an existing folder.

## Next steps for real clients

- Replace the shared PAT with a GitHub App: one `grafana_apps_provisioning_connection_v0alpha1` per Grafana, referenced from each repository's `spec.connection`.
- Remote state (S3 or Azure Blob) with one key per root/workspace.
