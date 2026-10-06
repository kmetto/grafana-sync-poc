variable "github_token" {
  description = "GitHub PAT with access to all client repos. Write-only: never stored in state."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "grafana_url" {
  type    = string
  default = "http://localhost:3000"
}

variable "grafana_auth" {
  description = "Grafana admin credentials as user:password, or a service account token."
  type        = string
  sensitive   = true
  default     = "admin:admin"
}
