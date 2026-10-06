variable "github_token" {
  description = "GitHub fine-grained PAT for the synced repo. Write-only: never stored in state."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "repo_url" {
  description = "GitHub repository both instances sync with."
  type        = string
  default     = "https://github.com/kmetto/grafana-sync-poc"
}

variable "grafana_dev_url" {
  type    = string
  default = "http://localhost:3000"
}

variable "grafana_prod_url" {
  type    = string
  default = "http://localhost:3001"
}

variable "grafana_auth" {
  description = "Grafana admin credentials as user:password, or a service account token."
  type        = string
  sensitive   = true
  default     = "admin:admin"
}
