# One run = one client. The Terraform workspace name is the client id (scripts/tf.sh selects it).
locals {
  clients   = jsondecode(file("${path.module}/../../clients.json"))
  client_id = terraform.workspace
  client    = lookup(local.clients, local.client_id, null)
}

# The invalid.invalid URL is only a defensive fallback; the guard below (precondition) is what blocks bad workspaces.
provider "grafana" {
  url  = try(local.client.prod_url, "http://invalid.invalid")
  auth = var.grafana_auth
}

resource "terraform_data" "workspace_guard" {
  lifecycle {
    precondition {
      condition     = local.client != null && try(local.client.prod_url, "") != ""
      error_message = "Workspace '${local.client_id}' is not a client in clients.json (or has no prod_url). Valid: ${join(", ", keys(local.clients))}. Use scripts/tf.sh client-prod <client-id> ..."
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
