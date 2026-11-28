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
  state_bucket   = "ticketrush-tfstate-${var.account_id}"
  workload_roles = "arn:aws:iam::${var.account_id}:role/ticketrush-dev-*"
}

# --- The permissions boundary: the MOST any workload role (e.g. a Lambda's) can ever do ---
# Jenkins may create ticketrush-dev-* roles only if they carry this boundary, so even an
# admin policy attached to such a role is capped here. Jenkins cannot change this policy:
# it lives in the ci/jenkins layer, which Jenkins has no access to.
data "aws_iam_policy_document" "workload_boundary" {
  statement {
    sid     = "OwnLogs"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:aws:logs:*:${var.account_id}:log-group:/aws/lambda/ticketrush-dev-*",
      "arn:aws:logs:*:${var.account_id}:log-group:/aws/lambda/ticketrush-dev-*:*",
    ]
  }
  statement {
    sid     = "OwnTables"
    actions = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:BatchGetItem", "dynamodb:BatchWriteItem", "dynamodb:ConditionCheckItem", "dynamodb:DescribeStream", "dynamodb:GetRecords", "dynamodb:GetShardIterator", "dynamodb:ListStreams"]
    resources = [
      "arn:aws:dynamodb:*:${var.account_id}:table/ticketrush-dev-*",
      "arn:aws:dynamodb:*:${var.account_id}:table/ticketrush-dev-*/*",
    ]
  }
  statement {
    sid       = "OwnKeys"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:Sign", "kms:Verify", "kms:GetPublicKey", "kms:DescribeKey"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["ticketrush"]
    }
  }
  statement {
    sid     = "OwnQueuesWorkflowsEvents"
    actions = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "states:StartExecution", "states:DescribeExecution", "events:PutEvents"]
    resources = [
      "arn:aws:sqs:*:${var.account_id}:ticketrush-dev-*",
      "arn:aws:states:*:${var.account_id}:stateMachine:ticketrush-dev-*",
      "arn:aws:states:*:${var.account_id}:execution:ticketrush-dev-*",
      "arn:aws:events:*:${var.account_id}:event-bus/ticketrush-dev-*",
    ]
  }
  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"] # X-Ray write APIs don't support resource scoping
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = "ticketrush-dev-workload-boundary"
  description = "Permissions boundary: the maximum any ticketrush-dev-* workload role may do"
  policy      = data.aws_iam_policy_document.workload_boundary.json
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
  # Creating a key has no existing resource to check a tag on, so require the tag ON THE REQUEST
  # (covers CreateKey and ReplicateKey, which creates the replica key in the other region)
  statement {
    sid       = "CreateTaggedTicketRushKeys"
    actions   = ["kms:CreateKey", "kms:TagResource"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = ["ticketrush"]
    }
  }

  # Lambda: only ticketrush-dev-* functions
  statement {
    sid       = "ManageTicketRushFunctions"
    actions   = ["lambda:*"]
    resources = ["arn:aws:lambda:*:${var.account_id}:function:ticketrush-dev-*"]
  }

  # API Gateway HTTP APIs, only in our two regions (HTTP API IDs are random, so they can't be scoped by name)
  statement {
    sid     = "ManageHttpApis"
    actions = ["apigateway:GET", "apigateway:POST", "apigateway:PUT", "apigateway:PATCH", "apigateway:DELETE", "apigateway:TagResource", "apigateway:UntagResource"]
    resources = [
      "arn:aws:apigateway:us-east-1::/apis",
      "arn:aws:apigateway:us-east-1::/apis/*",
      "arn:aws:apigateway:us-east-1::/tags/*",
      "arn:aws:apigateway:us-west-2::/apis",
      "arn:aws:apigateway:us-west-2::/apis/*",
      "arn:aws:apigateway:us-west-2::/tags/*",
    ]
  }

  # CloudWatch Logs: only ticketrush-dev log groups (Lambda logs + API access logs)
  statement {
    sid     = "ManageTicketRushLogGroups"
    actions = ["logs:*"]
    resources = [
      "arn:aws:logs:*:${var.account_id}:log-group:/aws/lambda/ticketrush-dev-*",
      "arn:aws:logs:*:${var.account_id}:log-group:/aws/lambda/ticketrush-dev-*:*",
      "arn:aws:logs:*:${var.account_id}:log-group:/aws/apigateway/ticketrush-dev-*",
      "arn:aws:logs:*:${var.account_id}:log-group:/aws/apigateway/ticketrush-dev-*:*",
    ]
  }
  # API Gateway's access-log delivery calls these on the caller's behalf; they don't support resource scoping
  statement {
    sid       = "ApiAccessLogDelivery"
    actions   = ["logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery", "logs:DeleteLogDelivery", "logs:ListLogDeliveries", "logs:PutResourcePolicy", "logs:DescribeResourcePolicies"]
    resources = ["*"]
  }

  # CloudWatch dashboards and alarms: only ones named ticketrush-* (reading them is covered by ReadOnlyAccess)
  statement {
    sid       = "ManageTicketRushDashboards"
    actions   = ["cloudwatch:PutDashboard", "cloudwatch:DeleteDashboards"]
    resources = ["arn:aws:cloudwatch::${var.account_id}:dashboard/ticketrush-*"]
  }
  statement {
    sid       = "ManageTicketRushAlarms"
    actions   = ["cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:TagResource", "cloudwatch:UntagResource"]
    resources = ["arn:aws:cloudwatch:*:${var.account_id}:alarm:ticketrush-*"]
  }

  # IAM: create and manage ticketrush-dev-* roles ONLY with the permissions boundary attached
  statement {
    sid       = "ManageWorkloadRolesWithBoundary"
    actions   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = [local.workload_roles]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.workload_boundary.arn]
    }
  }
  statement {
    sid       = "MaintainWorkloadRoles"
    actions   = ["iam:DeleteRole", "iam:TagRole", "iam:UntagRole", "iam:UpdateRole", "iam:UpdateRoleDescription", "iam:UpdateAssumeRolePolicy"]
    resources = [local.workload_roles]
  }
  # Hand those roles ONLY to Lambda
  statement {
    sid       = "PassWorkloadRolesToLambda"
    actions   = ["iam:PassRole"]
    resources = [local.workload_roles]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }
  # Never allow removing the boundary from a role
  statement {
    sid       = "NeverRemoveBoundary"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
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

output "workload_boundary_arn" {
  value = aws_iam_policy.workload_boundary.arn
}