# The instance's identity. AWS gives it short-lived credentials automatically:
# no access keys stored anywhere, the same idea as OIDC for GitHub.

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins" {
  name               = local.name
  description        = "Jenkins on EC2: SSM access, its own config parameters, and least-privilege deploys of envs/*"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

# Lets you open a session / port-forward through Systems Manager (no SSH, no open ports)
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Read ONLY Jenkins's own parameters (e.g. the admin password) at boot
data "aws_iam_policy_document" "jenkins_params" {
  statement {
    sid       = "ReadJenkinsParameters"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:us-east-1:${var.account_id}:parameter/ticketrush/jenkins/*"]
  }
}

resource "aws_iam_role_policy" "jenkins_params" {
  name   = "read-jenkins-parameters"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.jenkins_params.json
}

# --- Deploy permissions: read everything (to plan), write ONLY what envs/dev manages ---

# terraform plan refreshes every resource, so it needs to read them
resource "aws_iam_role_policy_attachment" "readonly" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

locals {
  state_bucket = "ticketrush-tfstate-${var.account_id}"
}

# Least privilege that grows with the project: each phase adds exactly what it needs, in a reviewed PR.
data "aws_iam_policy_document" "jenkins_deploy" {
  # State: ONLY the envs/* layers. Jenkins can't touch bootstrap, global/, or its own ci/jenkins state.
  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.state_bucket}"]
  }
  statement {
    sid       = "ReadWriteEnvState"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.state_bucket}/envs/*"]
  }

  # DynamoDB: only the ticketrush-dev-* tables, in any region (Global Tables live in two)
  statement {
    sid     = "ManageTicketRushTables"
    actions = ["dynamodb:*"]
    resources = [
      "arn:aws:dynamodb:*:${var.account_id}:table/ticketrush-dev-*",
      "arn:aws:dynamodb:*:${var.account_id}:table/ticketrush-dev-*/*",
    ]
  }

  # KMS: only keys tagged Project = ticketrush (the multi-Region data key and its replica)
  statement {
    sid       = "ManageTicketRushKeys"
    actions   = ["kms:*"]
    resources = ["*"] # key ARNs are random IDs, so access is scoped by tag instead
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["ticketrush"]
    }
  }
  statement {
    sid       = "ManageTicketRushKeyAliases"
    actions   = ["kms:CreateAlias", "kms:UpdateAlias", "kms:DeleteAlias"]
    resources = ["arn:aws:kms:*:${var.account_id}:alias/ticketrush-*"]
  }
}

resource "aws_iam_role_policy" "jenkins_deploy" {
  name   = "deploy-envs"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.jenkins_deploy.json
}

resource "aws_iam_instance_profile" "jenkins" {
  name = local.name
  role = aws_iam_role.jenkins.name
}