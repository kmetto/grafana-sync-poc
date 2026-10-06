terraform {
  required_providers {
    grafana = {
      source = "grafana/grafana"
    }
  }
}

resource "grafana_apps_provisioning_repository_v0alpha1" "this" {
  metadata {
    uid = var.uid
  }

  spec {
    title     = var.title
    type      = "github"
    workflows = var.workflows

    sync {
      enabled          = true
      target           = "folder"
      interval_seconds = var.interval_seconds
    }

    github {
      url    = var.repo_url
      branch = var.branch
      path   = var.path
      # explicit to match what Grafana stores (avoids a diff after import)
      generate_dashboard_previews = false
    }
  }

  secure {
    token = {
      create = var.github_token
    }
  }
  secure_version = var.token_version
}
