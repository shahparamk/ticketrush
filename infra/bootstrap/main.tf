terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }
  # Starts with local state. After the first apply, we move it into the bucket it creates.
  # State lives in the bucket this config created (migrated after the first apply)
  # The bucket name comes from backend.hcl (not committed): terraform init -backend-config=backend.hcl
  backend "s3" {
    key          = "bootstrap/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }

}
provider "aws" {
  region              = "us-east-1"
  allowed_account_ids = [var.account_id] # guardrail: refuse to run against any other account
  default_tags {
    tags = {
      Project   = "ticketrush"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "tfstate" {
  #checkov:skip=CKV_AWS_18:Access logging for a single-user state bucket isn't worth a second bucket
  #checkov:skip=CKV_AWS_144:Cross-region replication of state is out of scope; versioning covers recovery
  #checkov:skip=CKV2_AWS_62:No event notifications needed for a state bucket
  #checkov:skip=CKV_AWS_145:S3-managed encryption (SSE-S3) is sufficient for Terraform state here
  bucket = "ticketrush-tfstate-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true # losing state would orphan every resource
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled" # every state change is recoverable
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90 # keep 90 days of history, then clean up
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Refuse any request that isn't over HTTPS
data "aws_iam_policy_document" "tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tls_only.json
}

output "state_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}

variable "account_id" {
  description = "The only AWS account this config may touch (set in terraform.tfvars, not committed)"
  type        = string
}