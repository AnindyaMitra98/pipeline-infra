output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (internet-facing load balancers land here)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (EKS worker nodes land here)."
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "Availability zones in use."
  value       = local.azs
}
