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
3. Ensure `jq` is installed (required by `setup.sh` and `e2e.sh`).
4. Ensure `gh` is authenticated (required by `e2e.sh`).
5. `docker compose up -d`
6. `./scripts/setup.sh`

Login: `admin` / `admin`.

Using your own repo: set `GITHUB_REPO_URL` in `.env`; the repo needs `main` and `dev` branches.

## Demo (manual)

1. In dev, open folder **Git Sync POC (dev)**, create a dashboard, Save → it is committed to `dev`.
2. `gh pr create --base main --head dev --fill && gh pr merge dev --merge`
3. Within ~30s the dashboard shows up in prod under **Git Sync POC (prod)**; it cannot be saved there.

## Demo (automated)

`./scripts/e2e.sh` — commits a dashboard via dev, checks prod is read-only and doesn't see it before merge, opens and merges a PR, asserts it lands in prod.

Dashboards live in `grafana/`. Everything else in the repo is ignored by Grafana. Each `./scripts/e2e.sh` run leaves one `grafana/e2e-<timestamp>.json` dashboard and one merged PR in the repo — delete the file via the dev Grafana UI and promote with another PR if you want it gone.
