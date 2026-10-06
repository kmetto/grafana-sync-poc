variable "github_token" {
  description = "GitHub PAT with access to the client repo. Write-only: never stored in state."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "grafana_auth" {
  description = "Grafana admin credentials as user:password, or a service account token."
  type        = string
  sensitive   = true
  default     = "admin:admin"
}
