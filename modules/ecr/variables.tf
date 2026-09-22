variable "repository_name" {
  description = "Name of the ECR repository."
  type        = string
  default     = "sample-app"
}

variable "keep_image_count" {
  description = "How many recent images to retain before the lifecycle policy expires older ones."
  type        = number
  default     = 15
}

variable "tags" {
  description = "Tags applied to the repository."
  type        = map(string)
  default     = {}
}
