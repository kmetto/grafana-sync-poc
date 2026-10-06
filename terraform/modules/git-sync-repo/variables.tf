variable "uid" {
  description = "Repository resource name in Grafana."
  type        = string
}

variable "title" {
  description = "Display name; also the name of the folder Grafana creates."
  type        = string
}

variable "repo_url" {
  type = string
}

variable "branch" {
  type = string
}

variable "path" {
  description = "Subdirectory of the repo that Grafana reads and writes."
  type        = string
  default     = "grafana/"
}

variable "workflows" {
  description = "[\"write\"] commits UI saves to the branch, [\"branch\"] offers a PR, [] is read-only."
  type        = list(string)
}

variable "interval_seconds" {
  type    = number
  default = 30
}

variable "github_token" {
  type      = string
  sensitive = true
  ephemeral = true
}

variable "token_version" {
  description = "Bump to re-send github_token (write-only values are not diffed)."
  type        = number
  default     = 1
}
