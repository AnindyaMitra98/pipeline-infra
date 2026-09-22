variable "name_prefix" {
  description = "Prefix for IRSA role names."
  type        = string
  default     = "pipeline-portfolio"
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS cluster's OIDC provider."
  type        = string
}

variable "oidc_provider_url" {
  description = "Issuer URL of the EKS cluster's OIDC provider, without the https:// scheme."
  type        = string
}

variable "ecr_repository_arn" {
  description = "ECR repository Argo Image Updater is allowed to read tags from."
  type        = string
}

variable "secret_path_prefix" {
  description = "Secrets Manager name prefix External Secrets Operator may read, e.g. 'pipeline-app/'."
  type        = string
  default     = "pipeline-app/"
}

variable "argocd_namespace" {
  description = "Namespace ArgoCD and Argo Image Updater run in."
  type        = string
  default     = "argocd"
}

variable "external_secrets_namespace" {
  description = "Namespace External Secrets Operator runs in."
  type        = string
  default     = "external-secrets"
}

variable "tags" {
  description = "Tags applied to IAM resources."
  type        = map(string)
  default     = {}
}
