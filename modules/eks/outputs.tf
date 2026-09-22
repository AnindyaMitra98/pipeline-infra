output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = module.eks.cluster_endpoint
}

# Both of these feed every IRSA role's trust policy.
output "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider."
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "Issuer URL of the cluster's OIDC provider, without the https:// scheme."
  value       = module.eks.oidc_provider
}

output "node_security_group_id" {
  description = "Security group attached to the managed nodes."
  value       = module.eks.node_security_group_id
}

output "node_iam_role_arn" {
  description = "IAM role assumed by worker nodes (used in the ECR repository policy)."
  value       = module.eks.eks_managed_node_groups["default"].iam_role_arn
}
