variable "gitlab_url" {
  description = "GitLab OIDC issuer URL. Use your instance URL for self-managed GitLab."
  type        = string
  default     = "https://gitlab.com"
}

variable "audience" {
  description = "OIDC audience; must match the `aud` in the pipeline's id_tokens block."
  type        = string
  default     = "https://gitlab.com"
}

variable "thumbprints" {
  description = "TLS thumbprints for the GitLab OIDC provider."
  type        = list(string)
  # GitLab.com's certificate chain root. AWS performs its own chain validation
  # for public IdPs, so this rarely needs changing.
  default = ["a031c46782e6e6c662c2c87c76da9aa62ccabd8e"]
}

variable "allowed_subjects" {
  description = <<-EOT
    Which GitLab pipelines may assume the role, as `sub` claim patterns
    (StringLike, so `*` is allowed). Scope this as tightly as you can — an
    over-broad value here would let other GitLab projects assume your role.

    Example: ["project_path:my-group/pipeline-app:ref_type:branch:ref:main"]
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_subjects) > 0
    error_message = "At least one subject pattern is required; an empty list would deny everything."
  }

  validation {
    condition     = !contains(var.allowed_subjects, "*")
    error_message = "A bare '*' subject would let any GitLab.com project assume this role. Scope it to your project path."
  }
}

variable "ecr_repository_arn" {
  description = "ARN of the single ECR repository this role may push to."
  type        = string
}

variable "role_name" {
  description = "Name of the IAM role assumed by GitLab CI."
  type        = string
  default     = "pipeline-portfolio-gitlab-ci"
}

variable "tags" {
  description = "Tags applied to IAM resources."
  type        = map(string)
  default     = {}
}
