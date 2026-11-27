terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
  # The bucket name comes from backend.hcl (not committed): terraform init -backend-config=backend.hcl
  backend "s3" {
    key          = "envs/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

variable "account_id" {
  description = "The only AWS account this config may touch (set in terraform.tfvars, not committed)"
  type        = string
}

variable "app_version" {
  description = "Version stamped into the functions; Jenkins passes the short git commit"
  type        = string
  default     = "dev"
}

locals {
  project = "ticketrush"
  env     = "dev"
  name    = "${local.project}-${local.env}"
  tags = {
    Project     = local.project
    Environment = local.env
    ManagedBy   = "terraform"
  }
}

# Primary region: serves all writes (active-passive design)
provider "aws" {
  region              = "us-east-1"
  allowed_account_ids = [var.account_id] # guardrail: refuse to run against any other account
  default_tags {
    tags = local.tags
  }
}

# Standby region: a warm copy that takes over if us-east-1 fails
provider "aws" {
  alias               = "secondary"
  region              = "us-west-2"
  allowed_account_ids = [var.account_id]
  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}