variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
}

variable "cluster_version" {
  description = <<-EOT
    Kubernetes version for the control plane.

    Keep this on a version in STANDARD support. Once a version falls into
    extended support the control plane costs $0.60/hour instead of $0.10 --
    six times the price, charged silently with no change to your config.
    As of September 2026 that means 1.34, 1.35 or 1.36; 1.33 and older are
    already in extended support.
  EOT
  type        = string
  default     = "1.35"
}

variable "vpc_id" {
  description = "VPC to place the cluster in."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for the control plane ENIs and worker nodes."
  type        = list(string)
}

variable "public_access_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the public Kubernetes API endpoint. Defaults to
    open, which is fine for a short-lived demo cluster but should be narrowed
    to your own IP (e.g. ["203.0.113.4/32"]) for anything longer-lived.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  description = "Instance types for the managed node group."
  type        = list(string)
  # t3.medium (2 vCPU / 4 GiB) is the smallest size that comfortably fits
  # ArgoCD + Prometheus + the app across three namespaces.
  default = ["t3.medium"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT. SPOT roughly halves node cost for a demo cluster."
  type        = string
  default     = "SPOT"
}

variable "node_min_size" {
  description = "Minimum nodes in the managed node group."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum nodes in the managed node group."
  type        = number
  default     = 4
}

variable "node_desired_size" {
  description = "Desired nodes in the managed node group."
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags applied to cluster resources."
  type        = map(string)
  default     = {}
}
