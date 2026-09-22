# IRSA (IAM Roles for Service Accounts) roles for the in-cluster platform
# components.
#
# Each role is trusted by the *cluster's* OIDC provider and scoped to one
# specific Kubernetes ServiceAccount, so a compromised pod in another namespace
# cannot assume it. The bootstrap script annotates each ServiceAccount with the
# matching role ARN from this module's outputs.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Builds the standard IRSA trust policy for one ServiceAccount.
locals {
  roles = {
    image_updater = {
      name            = "${var.name_prefix}-argocd-image-updater"
      namespace       = var.argocd_namespace
      service_account = "argocd-image-updater"
      description     = "Lets Argo Image Updater list ECR tags."
    }
    external_secrets = {
      name            = "${var.name_prefix}-external-secrets"
      namespace       = var.external_secrets_namespace
      service_account = "external-secrets"
      description     = "Lets External Secrets Operator read app secrets from Secrets Manager."
    }
  }
}

data "aws_iam_policy_document" "trust" {
  for_each = local.roles

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${each.value.namespace}:${each.value.service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  for_each = local.roles

  name               = each.value.name
  description        = each.value.description
  assume_role_policy = data.aws_iam_policy_document.trust[each.key].json
  tags               = var.tags
}

# --- Argo Image Updater: read-only ECR -------------------------------------

data "aws_iam_policy_document" "image_updater" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrReadTags"
    effect = "Allow"
    actions = [
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = [var.ecr_repository_arn]
  }
}

resource "aws_iam_role_policy" "image_updater" {
  name   = "ecr-read"
  role   = aws_iam_role.this["image_updater"].id
  policy = data.aws_iam_policy_document.image_updater.json
}

# --- External Secrets Operator: scoped Secrets Manager read ----------------

data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid    = "ReadAppSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    # Scoped to a path prefix, not the whole account. The trailing wildcard
    # also covers the random 6-character suffix AWS appends to secret ARNs.
    resources = [
      "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.secret_path_prefix}*"
    ]
  }

  statement {
    sid       = "ListSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:ListSecrets"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "secretsmanager-read"
  role   = aws_iam_role.this["external_secrets"].id
  policy = data.aws_iam_policy_document.external_secrets.json
}
