output "repository_name" {
  description = "ECR repository name (set as the ECR_REPOSITORY CI/CD variable in GitLab)."
  value       = aws_ecr_repository.this.name
}

output "repository_url" {
  description = "Full repository URL, e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com/sample-app."
  value       = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  description = "Repository ARN, used to scope the GitLab push policy and the Image Updater read policy."
  value       = aws_ecr_repository.this.arn
}
