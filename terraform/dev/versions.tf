terraform {
  required_version = ">= 1.11" # write-only secrets (secure.token) need 1.11+

  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = ">= 4.28.1"
    }
  }
}
