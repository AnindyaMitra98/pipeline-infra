variable "region" {
  description = "AWS region for the whole platform."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix applied to resource names."
  type        = string
  default     = "pipeline-portfolio"
}

variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
  default     = "pipeline-portfolio"
}

variable "cluster_version" {
  description = <<-EOT
    Kubernetes version for the control plane. Must be a version in STANDARD
    support -- extended support costs $0.60/hour instead of $0.10. As of
    September 2026: 1.34, 1.35, 1.36.
  EOT
  type        = string
  default     = "1.35"
}

# --- Networking ------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones (minimum 2 for EKS)."
  type        = number
  default     = 2
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the Kubernetes API. Narrow this to your own IP for anything long-lived."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# --- Nodes -----------------------------------------------------------------

variable "node_instance_types" {
  description = "Instance types for the managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT."
  type        = string
  default     = "SPOT"
}

variable "node_min_size" {
  description = "Minimum nodes."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum nodes."
  type        = number
  default     = 4
}

variable "node_desired_size" {
  description = "Desired nodes."
  type        = number
  default     = 2
}

# --- Registry and CI -------------------------------------------------------

variable "ecr_repository_name" {
  description = "Name of the ECR repository for the sample app."
  type        = string
  default     = "sample-app"
}

variable "gitlab_url" {
  description = "GitLab OIDC issuer URL."
  type        = string
  default     = "https://gitlab.com"
}

variable "gitlab_audience" {
  description = "OIDC audience; must match the pipeline's id_tokens aud value."
  type        = string
  default     = "https://gitlab.com"
}

variable "gitlab_allowed_subjects" {
  description = <<-EOT
    GitLab `sub` claim patterns permitted to assume the CI role. Set this in
    terraform.tfvars to your own mirrored project path, e.g.

      gitlab_allowed_subjects = [
        "project_path:your-group/pipeline-app:ref_type:branch:ref:main"
      ]
  EOT
  type        = list(string)
}

# --- Application -----------------------------------------------------------

variable "environments" {
  description = "Environment names; one Secrets Manager entry and one Kubernetes namespace each."
  type        = list(string)
  default     = ["dev", "staging", "prod"]
}

variable "secret_path_prefix" {
  description = "Secrets Manager name prefix for app secrets."
  type        = string
  default     = "pipeline-app/"
}

variable "tags" {
  description = "Tags applied to every resource, for Cost Explorer filtering."
  type        = map(string)
  default = {
    Project   = "pipeline-portfolio"
    ManagedBy = "terraform"
  }
}
