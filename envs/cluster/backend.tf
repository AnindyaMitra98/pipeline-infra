# Remote state backend.
#
# The bucket and lock table are created by ../../bootstrap-state, which is
# applied once and lives outside the spin-up/spin-down cycle. The bucket name
# carries a random suffix for global uniqueness; it is not a secret, so it is
# committed here like any other configuration.
#
# Versioning on the bucket means every apply leaves a recoverable copy of the
# state; the DynamoDB table stops two applies racing each other.
#
# Forking this project? Apply ../../bootstrap-state yourself, then replace this
# block with the output of `terraform output -raw backend_config` and run
# `terraform init -migrate-state`.

terraform {
  backend "s3" {
    bucket         = "pipeline-portfolio-tfstate-qnuaq0"
    key            = "cluster/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "pipeline-portfolio-tf-locks"
    encrypt        = true
  }
}
