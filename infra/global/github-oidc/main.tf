terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }
  # The bucket name comes from backend.hcl (not committed)
  backend "s3" {
    key          = "global/github-oidc/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

variable "account_id" {
  description = "The only AWS account this config may touch"
  type        = string
}

variable "github_owner" {
  type    = string
  default = "shahparamk"
}

variable "github_owner_id" {
  description = "Numeric GitHub owner ID (GitHub's immutable OIDC subject format)"
  type        = string
}

variable "github_repo" {
  type    = string
  default = "ticketrush"
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID"
  type        = string
}

provider "aws" {
  region              = "us-east-1"
  allowed_account_ids = [var.account_id]
  default_tags {
    tags = {
      Project   = "ticketrush"
      ManagedBy = "terraform"
    }
  }
}

# The account's GitHub OIDC provider already exists (created by ShipYard); an account can only
# have one per URL, so reference it instead of creating a duplicate.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  # Immutable subject format: owner/repo names plus their numeric IDs
  repo_subject = "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}"
  state_bucket = "ticketrush-tfstate-${var.account_id}"
}

# Only pull requests in this repo can assume the role
data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.repo_subject}:pull_request"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "ticketrush-gha-plan"
  description          = "Read-only: GitHub Actions runs terraform plan on PRs. Cannot change AWS."
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

# Read everything (needed to compute a plan), change nothing
resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# The one write it needs: Terraform's S3 lock file while planning
data "aws_iam_policy_document" "plan_state_lock" {
  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.state_bucket}"]
  }
  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${local.state_bucket}/*"]
  }
  statement {
    sid       = "WriteLockFileOnly"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.state_bucket}/*.tflock"]
  }
}

resource "aws_iam_role_policy" "plan_state_lock" {
  name   = "terraform-state-lock"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_state_lock.json
}

output "plan_role_arn" {
  value = aws_iam_role.plan.arn
}