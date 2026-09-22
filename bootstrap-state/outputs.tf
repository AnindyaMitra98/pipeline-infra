# Feed these into ../envs/cluster/backend.tf after the first apply.
output "state_bucket" {
  description = "S3 bucket holding Terraform state for the cluster root."
  value       = aws_s3_bucket.state.id
}

output "lock_table" {
  description = "DynamoDB table used for state locking."
  value       = aws_dynamodb_table.locks.name
}

output "backend_config" {
  description = "Ready-to-paste backend block for ../envs/cluster/backend.tf."
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.state.id}"
        key            = "cluster/terraform.tfstate"
        region         = "${var.region}"
        dynamodb_table = "${aws_dynamodb_table.locks.name}"
        encrypt        = true
      }
    }
  EOT
}
