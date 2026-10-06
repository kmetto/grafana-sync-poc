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
3. Install Terraform >= 1.11 (`brew install hashicorp/tap/terraform`) and `jq`; authenticate `gh` (needed by `e2e.sh`).
4. `docker compose up -d`
5. `./scripts/tf.sh init && ./scripts/tf.sh apply` — creates the Git Sync Repository on each instance
6. `./scripts/verify.sh` — checks each instance can reach GitHub and has finished a sync (Terraform doesn't check this)

Login: `admin` / `admin`. If you change the admin password in the UI, update `GF_ADMIN_PASSWORD` in `.env`, otherwise Terraform and the scripts get 401s, and Grafana locks the login for 5 minutes after a few failed attempts.

Using your own repo: set `GITHUB_REPO_URL` in `.env`; the repo needs `main` and `dev` branches.

## Terraform layout

- `terraform/main.tf` — two calls of `modules/git-sync-repo`: `poc-dev` (branch `dev`, `workflows = ["write"]`) and `poc-prod` (branch `main`, `workflows = []` = read-only).
- `terraform/providers.tf` — one `grafana` provider per instance (aliases `dev`, `prod`).
- `scripts/tf.sh` — runs `terraform -chdir=terraform` with credentials from `.env` passed as `TF_VAR_*`. The GitHub token is a write-only attribute, so it never lands in `terraform.tfstate`; bump `token_version` in the module call to re-send a rotated token.
- State is local (`terraform/terraform.tfstate`, gitignored).

Terraform talks to the same Grafana API as the UI (`provisioning.grafana.app/v0alpha1`), so the instances must be running before `apply`.

To switch from a PAT to a GitHub App, add a `grafana_apps_provisioning_connection_v0alpha1` per instance and reference it from the repository's `spec.connection` instead of `secure.token`.

## Demo (manual)

1. In dev, open folder **Git Sync POC (dev)**, create a dashboard, Save → it is committed to `dev`.
2. `gh pr create --base main --head dev --fill && gh pr merge dev --merge`
3. Within ~30s the dashboard shows up in prod under **Git Sync POC (prod)**; it cannot be saved there.

## Demo (automated)

`./scripts/e2e.sh` — commits a dashboard via dev, checks prod is read-only and doesn't see it before merge, opens and merges a PR, asserts it lands in prod.

Dashboards live in `grafana/`. Everything else in the repo is ignored by Grafana. Each `./scripts/e2e.sh` run leaves one `grafana/e2e-<timestamp>.json` dashboard and one merged PR in the repo — delete the file via the dev Grafana UI and promote with another PR if you want it gone.
