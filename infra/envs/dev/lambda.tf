# The hello service: bundled once by the pipeline, deployed identically to both regions.

locals {
  hello_name   = "${local.name}-hello"
  boundary_arn = "arn:aws:iam::${var.account_id}:policy/ticketrush-dev-workload-boundary"
}

# The bundle built by `npm run build` (dist/index.js), zipped for Lambda
# The bundle built by `npm run build` (dist/index.mjs, an ES module), zipped for Lambda
data "archive_file" "hello" {
  type        = "zip"
  source_file = "${path.module}/../../../services/hello/dist/index.mjs"
  output_path = "${path.module}/../../../services/hello/dist/hello.zip"
}

# One execution role for both regions (IAM is global), capped by the permissions boundary
data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "hello" {
  name                 = local.hello_name
  description          = "Execution role for the hello Lambda in both regions"
  assume_role_policy   = data.aws_iam_policy_document.lambda_trust.json
  permissions_boundary = local.boundary_arn
}

data "aws_iam_policy_document" "hello" {
  statement {
    sid     = "WriteOwnLogs"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:aws:logs:*:${var.account_id}:log-group:/aws/lambda/${local.hello_name}:*",
    ]
  }
  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"] # X-Ray write APIs don't support resource scoping
  }
  statement {
    sid       = "DecryptEnvironment"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.data.arn, aws_kms_replica_key.data.arn]
  }
}

resource "aws_iam_role_policy" "hello" {
  name   = "hello-runtime"
  role   = aws_iam_role.hello.id
  policy = data.aws_iam_policy_document.hello.json
}

module "hello_primary" {
  source = "../../modules/regional-api"
  providers = {
    aws = aws
  }
  name        = local.hello_name
  zip_path    = data.archive_file.hello.output_path
  zip_hash    = data.archive_file.hello.output_base64sha256
  role_arn    = aws_iam_role.hello.arn
  kms_key_arn = aws_kms_key.data.arn
  app_version = var.app_version

  depends_on = [aws_iam_role_policy.hello]
}

module "hello_secondary" {
  source = "../../modules/regional-api"
  providers = {
    aws = aws.secondary
  }
  name        = local.hello_name
  zip_path    = data.archive_file.hello.output_path
  zip_hash    = data.archive_file.hello.output_base64sha256
  role_arn    = aws_iam_role.hello.arn
  kms_key_arn = aws_kms_replica_key.data.arn
  app_version = var.app_version

  depends_on = [aws_iam_role_policy.hello]
}