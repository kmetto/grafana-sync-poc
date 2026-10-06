# dev: UI saves are committed straight to branch `dev`.
module "dev" {
  source    = "./modules/git-sync-repo"
  providers = { grafana = grafana.dev }

  uid          = "poc-dev"
  title        = "Git Sync POC (dev)"
  repo_url     = var.repo_url
  branch       = "dev"
  workflows    = ["write"]
  github_token = var.github_token
}

# prod: read-only, follows `main`; changes arrive only via merged PRs dev -> main.
module "prod" {
  source    = "./modules/git-sync-repo"
  providers = { grafana = grafana.prod }

  uid          = "poc-prod"
  title        = "Git Sync POC (prod)"
  repo_url     = var.repo_url
  branch       = "main"
  workflows    = []
  github_token = var.github_token
}
