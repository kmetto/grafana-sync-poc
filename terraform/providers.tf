provider "grafana" {
  alias = "dev"
  url   = var.grafana_dev_url
  auth  = var.grafana_auth
}

provider "grafana" {
  alias = "prod"
  url   = var.grafana_prod_url
  auth  = var.grafana_auth
}
