# OIDC federation between GitLab CI and AWS.
#
# This is what removes static AWS credentials from the pipeline entirely.
# GitLab mints a short-lived JWT for each job; AWS validates it against
# GitLab's public keys and issues temporary credentials in exchange. Nothing
# long-lived is ever stored in GitLab CI/CD variables.
#
# The resulting role can push to exactly one ECR repository and can do nothing
# else — in particular it has no EKS permissions, because CI never deploys.
# Deployment is Argo's job, driven from the GitOps repo.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "aws_partition" "current" {}

resource "aws_iam_openid_connect_provider" "gitlab" {
  url = var.gitlab_url

  # Must match the `aud` in the pipeline's `id_tokens` block.
  client_id_list = [var.audience]

  # AWS verifies the OIDC provider's TLS chain itself for well-known IdPs, but
  # the thumbprint field is still required by the API. This is GitLab.com's
  # root CA thumbprint.
  thumbprint_list = var.thumbprints

  tags = var.tags
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.gitlab.arn]
    }

    # Audience must match exactly.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = [var.audience]
    }

    # Subject scoping is the real security control: only pipelines running on
    # the named branch of the named project can assume this role. Without this
    # condition ANY GitLab.com project on the internet could assume it.
    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values   = [for ref in var.allowed_subjects : ref]
    }
  }
}

locals {
  # e.g. "gitlab.com" — the condition keys are prefixed with the issuer host.
  oidc_host = replace(var.gitlab_url, "https://", "")
}

resource "aws_iam_role" "ci" {
  name                 = var.role_name
  description          = "Assumed by GitLab CI via OIDC to push images to ECR."
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600

  tags = var.tags
}

data "aws_iam_policy_document" "ecr_push" {
  # GetAuthorizationToken is account-wide by design — the API does not support
  # resource-level scoping for it.
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPushToSingleRepo"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [var.ecr_repository_arn]
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  name   = "${var.role_name}-ecr-push"
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ecr_push.json
}
