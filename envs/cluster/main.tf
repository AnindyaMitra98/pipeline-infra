# The one Terraform root for the whole platform.
#
# A single `terraform apply` here provisions networking, the EKS cluster, ECR,
# the GitLab OIDC trust, and every IRSA role. Terraform's dependency graph
# handles ordering; there is no multi-phase apply to remember.
#
# What this root deliberately does NOT do: install anything *onto* the cluster.
# ArgoCD, External Secrets Operator, Argo Image Updater and Prometheus are
# installed by ../../bootstrap/install.ps1 via Helm. Terraform's Kubernetes and
# Helm providers need a reachable cluster at plan time, which turns a clean
# apply into a fragile two-phase dance and couples AWS-infrastructure state to
# cluster-workload state. Terraform owns AWS; Helm owns what runs on the
# cluster. The seam between them is the IRSA role ARNs in outputs.tf.

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
    tags = local.tags
  }
}

locals {
  tags = merge(var.tags, { Environment = "shared" })
}

module "networking" {
  source = "../../modules/networking"

  name         = var.name_prefix
  cluster_name = var.cluster_name
  vpc_cidr     = var.vpc_cidr
  az_count     = var.az_count
}

module "eks" {
  source = "../../modules/eks"

  cluster_name        = var.cluster_name
  cluster_version     = var.cluster_version
  vpc_id              = module.networking.vpc_id
  private_subnet_ids  = module.networking.private_subnet_ids
  public_access_cidrs = var.public_access_cidrs

  node_instance_types = var.node_instance_types
  node_capacity_type  = var.node_capacity_type
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  node_desired_size   = var.node_desired_size

  tags = local.tags
}

module "ecr" {
  source = "../../modules/ecr"

  repository_name = var.ecr_repository_name
  tags            = local.tags
}

module "iam_oidc_gitlab" {
  source = "../../modules/iam-oidc-gitlab"

  gitlab_url         = var.gitlab_url
  audience           = var.gitlab_audience
  allowed_subjects   = var.gitlab_allowed_subjects
  ecr_repository_arn = module.ecr.repository_arn
  role_name          = "${var.name_prefix}-gitlab-ci"
  tags               = local.tags
}

module "irsa" {
  source = "../../modules/irsa"

  name_prefix        = var.name_prefix
  oidc_provider_arn  = module.eks.oidc_provider_arn
  oidc_provider_url  = module.eks.oidc_provider_url
  ecr_repository_arn = module.ecr.repository_arn
  secret_path_prefix = var.secret_path_prefix
  tags               = local.tags
}

# --- Application secrets ---------------------------------------------------
# One Secrets Manager entry per environment, read in-cluster by External
# Secrets Operator. These hold the APP_GREETING value the app requires to pass
# its readiness probe — a small but real secret, so the ESO path is genuinely
# exercised rather than mocked.

resource "aws_secretsmanager_secret" "app" {
  for_each = toset(var.environments)

  name        = "${var.secret_path_prefix}${each.key}"
  description = "Runtime config for the sample app in ${each.key}."

  # Without this, a destroyed secret lingers for 7-30 days and blocks
  # re-creating it under the same name on the next spin-up.
  recovery_window_in_days = 0

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "app" {
  for_each = aws_secretsmanager_secret.app

  secret_id = each.value.id
  secret_string = jsonencode({
    APP_GREETING = "Hello from ${each.key} — deployed by ArgoCD"
  })
}
