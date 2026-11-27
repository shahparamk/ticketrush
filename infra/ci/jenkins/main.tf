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
    key          = "ci/jenkins/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

variable "account_id" {
  description = "The only AWS account this config may touch"
  type        = string
}

variable "jenkins_image" {
  description = "Pinned Jenkins LTS image, e.g. jenkins/jenkins:2.xxx.x-lts-jdk21"
  type        = string
}

variable "agent_base_image" {
  description = "Jenkins inbound-agent base image, pinned by tag AND digest (tag@sha256:...)"
  type        = string
}

variable "terraform_version" {
  description = "Terraform version inside the build agent; keep it equal to the laptop and GitHub Actions"
  type        = string
}

variable "awscli_version" {
  description = "AWS CLI v2 version inside the build agent"
  type        = string
}

variable "node_version" {
  description = "Node.js version inside the build agent (no leading v), matching the Lambda runtime's major version"
  type        = string
}

variable "instance_type" {
  description = "Jenkins needs ~2 GB for itself plus room for Docker build agents"
  type        = string
  default     = "t3.medium"
}

locals {
  name = "ticketrush-jenkins"
}

provider "aws" {
  region              = "us-east-1"
  allowed_account_ids = [var.account_id]
  default_tags {
    tags = {
      Project   = "ticketrush"
      Component = "jenkins"
      ManagedBy = "terraform"
    }
  }
}