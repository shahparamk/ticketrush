# The TicketRush ticketing API: one function per concern, each with only the permissions it needs.
#   read:       event details + seat map (DynamoDB read)
#   session:    issues buyer tokens (KMS Sign) and serves GET /me
#   authorizer: verifies buyer tokens (KMS GetPublicKey only)
#   hold:       holds/releases seats (conditional transactions on seats, buyers, idempotency)

locals {
  ticketing_name = "${local.name}-ticketing"
  ticketing_fns  = toset(["read", "session", "authorizer", "hold"])

  table_arns = {
    for k, t in aws_dynamodb_table.this : k => "arn:aws:dynamodb:*:${var.account_id}:table/${t.name}"
  }
  data_key_arns    = [aws_kms_key.data.arn, aws_kms_replica_key.data.arn]
  signing_key_arns = [aws_kms_key.signing.arn, aws_kms_replica_key.signing.arn]

  hold_routes = [
    "POST /events/{eventId}/seats/{seatId}/hold",
    "DELETE /events/{eventId}/seats/{seatId}/hold",
  ]

  ticketing_role_descriptions = {
    read       = "Ticketing read Lambda (both regions): read-only access to events and seats"
    session    = "Ticketing session Lambda (both regions): signs buyer tokens with KMS"
    authorizer = "Ticketing authorizer Lambda (both regions): verifies buyer tokens with the KMS public key"
    hold       = "Ticketing hold Lambda (both regions): conditional writes to seats, buyers and idempotency"
  }
}

# One zip per function, from the bundles built by `npm run build`
data "archive_file" "ticketing" {
  for_each    = local.ticketing_fns
  type        = "zip"
  source_file = "${path.module}/../../../services/ticketing/dist/${each.key}/index.mjs"
  output_path = "${path.module}/../../../services/ticketing/dist/${each.key}.zip"
}

# --- Permissions every function gets: its own logs, tracing, and decrypting its environment ---
data "aws_iam_policy_document" "ticketing_base" {
  for_each = local.ticketing_fns

  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:${var.account_id}:log-group:/aws/lambda/${local.ticketing_name}-${each.key}:*"]
  }
  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"] # X-Ray write APIs don't support resource scoping
  }
  statement {
    sid       = "DecryptEnvironment"
    actions   = ["kms:Decrypt"]
    resources = local.data_key_arns
    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values   = ["lambda.*.amazonaws.com"]
    }
  }
}

# --- What each function needs beyond the base ---
data "aws_iam_policy_document" "ticketing_read_access" {
  statement {
    sid       = "ReadEventsAndSeats"
    actions   = ["dynamodb:GetItem", "dynamodb:Query"]
    resources = [local.table_arns["events"], local.table_arns["seats"]]
  }
  # The tables are encrypted with our KMS key; reads need it, but only through DynamoDB
  statement {
    sid       = "DecryptThroughDynamoDB"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = local.data_key_arns
    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values   = ["dynamodb.*.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ticketing_sign" {
  statement {
    sid       = "SignBuyerTokens"
    actions   = ["kms:Sign"]
    resources = local.signing_key_arns
  }
}

data "aws_iam_policy_document" "ticketing_verify" {
  statement {
    sid       = "ReadSigningPublicKey"
    actions   = ["kms:GetPublicKey"]
    resources = local.signing_key_arns
  }
}

data "aws_iam_policy_document" "ticketing_hold_access" {
  # Item-level reads and conditional writes only: no Scan, no DeleteItem, no table changes.
  # (TransactWriteItems has no IAM action of its own; it needs the per-item actions below.)
  statement {
    sid       = "HoldTransactions"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:ConditionCheckItem"]
    resources = [local.table_arns["seats"], local.table_arns["buyers"], local.table_arns["idempotency"]]
  }
  # Writing to KMS-encrypted tables needs the key, but only through DynamoDB
  statement {
    sid       = "UseKeyThroughDynamoDB"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = local.data_key_arns
    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values   = ["dynamodb.*.amazonaws.com"]
    }
  }
}

locals {
  ticketing_extra_policy = {
    read       = data.aws_iam_policy_document.ticketing_read_access.json
    session    = data.aws_iam_policy_document.ticketing_sign.json
    authorizer = data.aws_iam_policy_document.ticketing_verify.json
    hold       = data.aws_iam_policy_document.ticketing_hold_access.json
  }
}

data "aws_iam_policy_document" "ticketing" {
  for_each                = local.ticketing_fns
  source_policy_documents = [data.aws_iam_policy_document.ticketing_base[each.key].json, local.ticketing_extra_policy[each.key]]
}

# --- One role per function, all capped by the permissions boundary ---
resource "aws_iam_role" "ticketing" {
  for_each             = local.ticketing_fns
  name                 = "${local.ticketing_name}-${each.key}"
  description          = local.ticketing_role_descriptions[each.key]
  assume_role_policy   = data.aws_iam_policy_document.lambda_trust.json
  permissions_boundary = local.boundary_arn
}

resource "aws_iam_role_policy" "ticketing" {
  for_each = local.ticketing_fns
  name     = "ticketing-${each.key}-runtime"
  role     = aws_iam_role.ticketing[each.key].id
  policy   = data.aws_iam_policy_document.ticketing[each.key].json
}

# The read role already exists under its old name in the code: rename it in state, don't recreate it
moved {
  from = aws_iam_role.ticketing_read
  to   = aws_iam_role.ticketing["read"]
}

moved {
  from = aws_iam_role_policy.ticketing_read
  to   = aws_iam_role_policy.ticketing["read"]
}

# The same functions in both regions; only the region role and keys differ
locals {
  ticketing_functions = {
    for region_role in ["primary", "standby"] : region_role => {
      read = {
        zip_path             = data.archive_file.ticketing["read"].output_path
        zip_hash             = data.archive_file.ticketing["read"].output_base64sha256
        role_arn             = aws_iam_role.ticketing["read"].arn
        routes               = ["GET /events/{eventId}", "GET /events/{eventId}/seats"]
        memory_size          = 256
        timeout              = 10
        reserved_concurrency = 20
        environment = {
          EVENTS_TABLE = aws_dynamodb_table.this["events"].name
          SEATS_TABLE  = aws_dynamodb_table.this["seats"].name
          REGION_ROLE  = region_role
          APP_VERSION  = var.app_version
        }
      }
      session = {
        zip_path             = data.archive_file.ticketing["session"].output_path
        zip_hash             = data.archive_file.ticketing["session"].output_base64sha256
        role_arn             = aws_iam_role.ticketing["session"].arn
        routes               = ["POST /session", "GET /me"]
        memory_size          = 256
        timeout              = 10
        reserved_concurrency = 20
        environment = {
          SIGNING_KEY_ID = aws_kms_alias.signing.name # the alias has the same name in both regions
          REGION_ROLE    = region_role
          APP_VERSION    = var.app_version
        }
      }
      authorizer = {
        zip_path             = data.archive_file.ticketing["authorizer"].output_path
        zip_hash             = data.archive_file.ticketing["authorizer"].output_base64sha256
        role_arn             = aws_iam_role.ticketing["authorizer"].arn
        routes               = []
        memory_size          = 256
        timeout              = 5
        reserved_concurrency = 50
        environment = {
          SIGNING_KEY_ID = aws_kms_alias.signing.name
          REGION_ROLE    = region_role
          APP_VERSION    = var.app_version
        }
      }
      hold = {
        zip_path             = data.archive_file.ticketing["hold"].output_path
        zip_hash             = data.archive_file.ticketing["hold"].output_base64sha256
        role_arn             = aws_iam_role.ticketing["hold"].arn
        routes               = local.hold_routes
        memory_size          = 256
        timeout              = 10
        reserved_concurrency = 50
        environment = {
          SEATS_TABLE       = aws_dynamodb_table.this["seats"].name
          BUYERS_TABLE      = aws_dynamodb_table.this["buyers"].name
          IDEMPOTENCY_TABLE = aws_dynamodb_table.this["idempotency"].name
          REGION_ROLE       = region_role # the standby answers writes with 503 (failover flips this in Phase 6)
          APP_VERSION       = var.app_version
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
  authorizer_function  = "authorizer"
  protected_routes     = concat(["GET /me"], local.hold_routes)
  throttle_rate_limit  = 50
  throttle_burst_limit = 100

  depends_on = [aws_iam_role_policy.ticketing]
}

module "ticketing_secondary" {
  source = "../../modules/service-api"
  providers = {
    aws = aws.secondary
  }
  name                 = local.ticketing_name
  kms_key_arn          = aws_kms_replica_key.data.arn
  functions            = local.ticketing_functions["standby"]
  authorizer_function  = "authorizer"
  protected_routes     = concat(["GET /me"], local.hold_routes)
  throttle_rate_limit  = 50
  throttle_burst_limit = 100

  depends_on = [aws_iam_role_policy.ticketing]
}