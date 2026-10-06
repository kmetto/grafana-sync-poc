# Grafana Git Sync POC — Design

Date: 2026-10-06

## Goal

Prove that Grafana Git Sync can drive a dev → prod promotion flow through GitHub pull requests:

- **dev** Grafana: dashboard changes made in the UI are committed to Git.
- **prod** Grafana: dashboards are pulled from Git only; changes reach prod only after a PR is merged.

## Decisions

| Topic | Decision |
|---|---|
| Git host | GitHub (this repo, published via `gh repo create`, private) |
| Branches | `dev` — written by dev Grafana; `main` — read by prod Grafana |
| Promotion | PR `dev → main`, merged manually |
| Mechanism | Native Git Sync on both instances |
| Sync trigger | Polling, `intervalSeconds: 30` (no webhooks — Grafana runs on localhost) |
| Auth | GitHub fine-grained PAT (Contents + Pull requests: read/write), stored in `.env` (gitignored) |

## Architecture

```
            commit (UI save)                 PR dev → main (merge)
grafana-dev ───────────────► GitHub: dev ─────────────────────────► GitHub: main
  :3000                                                                 │
  Repository: branch=dev, workflows=[write]                             │ poll 30s
                                                                        ▼
                                                                   grafana-prod :3001
                                                   Repository: branch=main, workflows=[]
```

Both Repository resources use the same repo URL and `path: grafana/`; they differ only in branch and workflows. Sync target: `folder` (Grafana creates a folder named after the repository).

## Components

- `docker-compose.yml` — services `grafana-dev` (port 3000) and `grafana-prod` (port 3001), `grafana/grafana` 12.x image, Git Sync feature toggles enabled via env vars, named volumes for persistence. Exact image tag and toggle names are verified at implementation time.
- `repos/dev.yaml`, `repos/prod.yaml` — Repository resource templates (`provisioning.grafana.app/v0alpha1`), with `${GITHUB_REPO_URL}` and token substituted by the setup script.
- `scripts/setup.sh` — waits for both instances to become healthy, then creates the Repository resource in each via the Grafana API. Idempotent: safe to rerun.
- `.env.example` — documents `GITHUB_TOKEN`, `GITHUB_REPO_URL`, admin credentials. `.env` is gitignored.
- `grafana/` — dashboard JSON managed by Git Sync. Seeded with one sample dashboard so the first sync has content.
- `README.md` — how to run, demo scenario.

## Error handling

- `setup.sh` fails loudly (non-zero exit, API response printed) if Grafana is not reachable, the token is missing, or the Repository creation returns an error.
- Repository health/sync status is checked after creation and printed.

## Verification (demo scenario = success criteria)

1. `docker compose up -d && ./scripts/setup.sh` → both instances show the synced folder with the sample dashboard.
2. Create a new dashboard in dev UI and save it into the synced folder → a commit with `grafana/<dashboard>.json` appears on branch `dev`.
3. `gh pr create --base main --head dev` and merge it.
4. Within ~30s the new dashboard appears in prod; prod UI does not allow saving it (read-only).
5. Edit the dashboard in dev → new PR → merge → change appears in prod.

## Out of scope

Webhooks, GitHub App auth, branch protection, CI validation of PRs, alerting/other resource types.
