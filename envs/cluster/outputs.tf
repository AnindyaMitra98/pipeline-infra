# These outputs are the seam between Terraform (AWS) and Helm (cluster).
# infra/bootstrap/install.ps1 reads them to wire up ServiceAccount annotations
# and registry URLs, so nothing has to be copied by hand.

output "region" {
  description = "AWS region."
  value       = var.region
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = module.eks.cluster_endpoint
}

output "configure_kubectl" {
  description = "Command to point kubectl at the new cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

# --- Registry --------------------------------------------------------------

output "ecr_repository_name" {
  description = "Set as the ECR_REPOSITORY CI/CD variable in GitLab."
  value       = module.ecr.repository_name
}

output "ecr_repository_url" {
  description = "Full ECR repository URL; goes into the Helm chart's image.repository."
  value       = module.ecr.repository_url
}

# --- GitLab CI -------------------------------------------------------------

output "gitlab_ci_role_arn" {
  description = "Set as the AWS_ROLE_ARN CI/CD variable in GitLab."
  value       = module.iam_oidc_gitlab.role_arn
}

# --- IRSA ------------------------------------------------------------------

output "image_updater_role_arn" {
  description = "IRSA role ARN for the argocd-image-updater ServiceAccount."
  value       = module.irsa.image_updater_role_arn
}

output "external_secrets_role_arn" {
  description = "IRSA role ARN for the external-secrets ServiceAccount."
  value       = module.irsa.external_secrets_role_arn
}

# --- Convenience -----------------------------------------------------------

output "gitlab_ci_variables" {
  description = "The complete set of GitLab CI/CD variables to configure. None of these are secrets."
  value = {
    AWS_ROLE_ARN   = module.iam_oidc_gitlab.role_arn
    AWS_REGION     = var.region
    ECR_REPOSITORY = module.ecr.repository_name
  }
}
