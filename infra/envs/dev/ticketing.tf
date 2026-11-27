# The TicketRush ticketing API: one function per concern (least privilege per function).
# Step 2a: "read" (event details + seat map). Later steps add session, authorizer, hold.

locals {
  ticketing_name = "${local.name}-ticketing"
  ticketing_fns  = toset(["read"])
  table_arns = {
    for k, t in aws_dynamodb_table.this : k => "arn:aws:dynamodb:*:${var.account_id}:table/${t.name}"
  }
}

# One zip per function, from the bundle built by `npm run build`
data "archive_file" "ticketing" {
  for_each    = local.ticketing_fns
  type        = "zip"
  source_file = "${path.module}/../../../services/ticketing/dist/${each.key}/index.mjs"
  output_path = "${path.module}/../../../services/ticketing/dist/${each.key}.zip"
}

# --- The read function's role: it can READ the events and seats tables, and nothing else ---
resource "aws_iam_role" "ticketing_read" {
  name                 = "${local.ticketing_name}-read"
  description          = "Ticketing read Lambda (both regions): read-only access to events and seats"
  assume_role_policy   = data.aws_iam_policy_document.lambda_trust.json
  permissions_boundary = local.boundary_arn
}

data "aws_iam_policy_document" "ticketing_read" {
  statement {
    sid       = "ReadEventsAndSeats"
    actions   = ["dynamodb:GetItem", "dynamodb:Query"]
    resources = [local.table_arns["events"], local.table_arns["seats"]]
  }
  # The tables are encrypted with our KMS key; reads need it, but only through DynamoDB
  statement {
    sid       = "DecryptThroughDynamoDB"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.data.arn, aws_kms_replica_key.data.arn]
    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values   = ["dynamodb.*.amazonaws.com"]
    }
  }
  statement {
    sid       = "DecryptEnvironment"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.data.arn, aws_kms_replica_key.data.arn]
    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values   = ["lambda.*.amazonaws.com"]
    }
  }
  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:${var.account_id}:log-group:/aws/lambda/${local.ticketing_name}-read:*"]
  }
  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"] # X-Ray write APIs don't support resource scoping
  }
}

resource "aws_iam_role_policy" "ticketing_read" {
  name   = "ticketing-read-runtime"
  role   = aws_iam_role.ticketing_read.id
  policy = data.aws_iam_policy_document.ticketing_read.json
}

# The same functions in both regions; only the region role and key differ
locals {
  ticketing_functions = {
    for region_role in ["primary", "standby"] : region_role => {
      read = {
        zip_path             = data.archive_file.ticketing["read"].output_path
        zip_hash             = data.archive_file.ticketing["read"].output_base64sha256
        role_arn             = aws_iam_role.ticketing_read.arn
        routes               = ["GET /events/{eventId}", "GET /events/{eventId}/seats"]
        memory_size          = 256
        timeout              = 10
        reserved_concurrency = 20
        environment = {
          EVENTS_TABLE = aws_dynamodb_table.this["events"].name
          SEATS_TABLE  = aws_dynamodb_table.this["seats"].name
          REGION_ROLE  = region_role # standby will reject writes (step 2c); failover flips it (Phase 6)
          APP_VERSION  = var.app_version
        }
      }
    }
  }
}

module "ticketing_primary" {
  source = "../../modules/service-api"
  providers = {
    aws = aws
  }
  name                 = local.ticketing_name
  kms_key_arn          = aws_kms_key.data.arn
  functions            = local.ticketing_functions["primary"]
  throttle_rate_limit  = 50
  throttle_burst_limit = 100

  depends_on = [aws_iam_role_policy.ticketing_read]
}

module "ticketing_secondary" {
  source = "../../modules/service-api"
  providers = {
    aws = aws.secondary
  }
  name                 = local.ticketing_name
  kms_key_arn          = aws_kms_replica_key.data.arn
  functions            = local.ticketing_functions["standby"]
  throttle_rate_limit  = 50
  throttle_burst_limit = 100

  depends_on = [aws_iam_role_policy.ticketing_read]
}