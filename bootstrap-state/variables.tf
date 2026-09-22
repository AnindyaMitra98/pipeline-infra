variable "region" {
  description = "AWS region for the state bucket and lock table."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_prefix" {
  description = "Prefix for the Terraform state bucket; a random suffix is appended for global uniqueness."
  type        = string
  default     = "pipeline-portfolio-tfstate"
}

variable "lock_table_name" {
  description = "Name of the DynamoDB table used for Terraform state locking."
  type        = string
  default     = "pipeline-portfolio-tf-locks"
}

variable "tags" {
  description = "Tags applied to every resource, for Cost Explorer filtering."
  type        = map(string)
  default = {
    Project   = "pipeline-portfolio"
    ManagedBy = "terraform"
  }
}
