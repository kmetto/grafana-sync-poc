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
