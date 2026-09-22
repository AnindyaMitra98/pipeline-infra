# One-time bootstrap: creates the S3 bucket and DynamoDB lock table that the
# main Terraform root (../envs/cluster) uses as its remote backend.
#
# This root deliberately keeps its own state LOCAL — it cannot store state in a
# bucket it has not created yet. Apply it once; after that it is essentially
# never touched, and it is NOT part of the spin-up/spin-down cycle. Destroying
# the cluster does not destroy this.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = var.tags
  }
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# S3 bucket names are globally unique, so a random suffix avoids collisions
# with anyone else who has ever run this project.
resource "aws_s3_bucket" "state" {
  bucket = "${var.state_bucket_prefix}-${random_string.suffix.result}"

  # Guard rail: this bucket holds the state for everything else. Refuse to
  # destroy it by accident.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "locks" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
