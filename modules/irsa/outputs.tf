output "image_updater_role_arn" {
  description = "Annotate the argocd-image-updater ServiceAccount with this."
  value       = aws_iam_role.this["image_updater"].arn
}

output "external_secrets_role_arn" {
  description = "Annotate the external-secrets ServiceAccount with this."
  value       = aws_iam_role.this["external_secrets"].arn
}
