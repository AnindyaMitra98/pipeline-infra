output "role_arn" {
  description = "Set this as the AWS_ROLE_ARN CI/CD variable in the GitLab project."
  value       = aws_iam_role.ci.arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitLab OIDC provider in this AWS account."
  value       = aws_iam_openid_connect_provider.gitlab.arn
}
