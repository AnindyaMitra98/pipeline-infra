# Remote state backend.
#
# The bucket name is not known until ../../bootstrap-state has been applied
# (it carries a random suffix for global uniqueness), so this block ships
# commented out. Until you uncomment it, Terraform uses local state — which
# works fine for a solo run but loses the locking and versioning story.
#
# To enable it:
#   1. cd ../../bootstrap-state && terraform apply
#   2. terraform output -raw backend_config   # prints the exact block below
#   3. paste it here, uncomment, then run `terraform init -migrate-state`

# terraform {
#   backend "s3" {
#     bucket         = "pipeline-portfolio-tfstate-xxxxxx"
#     key            = "cluster/terraform.tfstate"
#     region         = "us-east-1"
#     dynamodb_table = "pipeline-portfolio-tf-locks"
#     encrypt        = true
#   }
# }
