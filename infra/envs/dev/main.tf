terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }
  backend "s3" {
    bucket       = "ticketrush-tfstate-717279721195"
    key          = "envs/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
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
  allowed_account_ids = ["717279721195"]
  default_tags {
    tags = local.tags
  }
}

# Standby region: a warm copy that takes over if us-east-1 fails
provider "aws" {
  alias               = "secondary"
  region              = "us-west-2"
  allowed_account_ids = ["717279721195"]
  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}