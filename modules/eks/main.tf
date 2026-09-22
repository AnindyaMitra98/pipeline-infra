# EKS cluster, built on the community terraform-aws-modules/eks module.
#
# Composing the community module rather than hand-rolling ~40 resources
# (control plane, node group, security groups, IRSA OIDC provider, addon
# wiring) is the idiomatic choice and keeps this readable. The interesting
# decisions — node sizing, addon set, public endpoint scoping — are all here.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  # Public endpoint so kubectl/ArgoCD CLI work from a laptop without a bastion
  # or VPN. Locked down by CIDR — see var.public_access_cidrs.
  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.public_access_cidrs
  cluster_endpoint_private_access      = true

  # Creates the cluster's OIDC provider, which every IRSA role trusts.
  enable_irsa = true

  # Grant the identity running `terraform apply` cluster-admin, so the very
  # next step (helm install / kubectl apply) works without a second auth dance.
  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API_AND_CONFIG_MAP"

  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni    = { most_recent = true }
    # No aws-ebs-csi-driver on purpose: nothing in this cluster uses a
    # PersistentVolume (Prometheus and Grafana run with ephemeral storage), and
    # leaving it out removes a class of stuck-volume failures on teardown.
  }

  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types
      capacity_type  = var.node_capacity_type

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # 30 GiB is enough for the platform addons plus three copies of a small
      # Node app, with room for image layers.
      disk_size = 30
    }
  }

  tags = var.tags
}
