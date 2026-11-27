# One region's slice of the hello service: Lambda + HTTP API + encrypted logs.
# Used twice by envs/dev (us-east-1 and us-west-2), so the regions can't drift apart.
terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

variable "name" {
  description = "Resource name, e.g. ticketrush-dev-hello"
  type        = string
}

variable "zip_path" {
  description = "Path to the bundled Lambda zip"
  type        = string
}

variable "zip_hash" {
  description = "base64 SHA-256 of the zip, so Terraform redeploys only when the code changes"
  type        = string
}

variable "role_arn" {
  description = "Execution role (IAM is global, so both regions share one role)"
  type        = string
}

variable "kms_key_arn" {
  description = "This region's copy of the multi-Region data key"
  type        = string
}

variable "app_version" {
  description = "Version reported by the function (the git commit, when deployed by Jenkins)"
  type        = string
}

resource "aws_cloudwatch_log_group" "lambda" {
  #checkov:skip=CKV_AWS_338:30-day retention for a dev environment (cost); production would keep a year
  name              = "/aws/lambda/${var.name}"
  retention_in_days = 30
  kms_key_id        = var.kms_key_arn
}

resource "aws_lambda_function" "this" {
  #checkov:skip=CKV_AWS_116:Invoked synchronously by API Gateway; errors go back to the caller, so an async dead-letter queue doesn't apply
  #checkov:skip=CKV_AWS_117:No VPC needed (no private resources to reach); a VPC would add NAT gateway cost and cold-start time
  #checkov:skip=CKV_AWS_272:Code signing is a hardening item for later
  function_name                  = var.name
  role                           = var.role_arn
  runtime                        = "nodejs24.x"
  handler                        = "index.handler"
  architectures                  = ["arm64"] # Graviton: cheaper per ms; the bundle is plain JS, so it runs anywhere
  filename                       = var.zip_path
  source_code_hash               = var.zip_hash
  memory_size                    = 128
  timeout                        = 5
  reserved_concurrent_executions = 10 # caps how far a burst of traffic can scale this function
  kms_key_arn                    = var.kms_key_arn

  environment {
    variables = {
      APP_VERSION = var.app_version
    }
  }

  tracing_config {
    mode = "Active" # X-Ray traces for every request
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.lambda.name
  }
}

resource "aws_cloudwatch_log_group" "api" {
  #checkov:skip=CKV_AWS_338:30-day retention for a dev environment (cost); production would keep a year
  name              = "/aws/apigateway/${var.name}-api"
  retention_in_days = 30
  kms_key_id        = var.kms_key_arn
}

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_function.this.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "hello" {
  #checkov:skip=CKV_AWS_309:Public read-only endpoint by design; buyer authentication (KMS-signed tokens) arrives in Phase 2
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /hello"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  # Throttle the public URL so it can't be used to run up costs
  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId = "$context.requestId"
      ip        = "$context.identity.sourceIp"
      method    = "$context.httpMethod"
      path      = "$context.path"
      status    = "$context.status"
      latencyMs = "$context.responseLatency"
    })
  }
}

# Let this API (and only this route) invoke the function
resource "aws_lambda_permission" "api" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/GET/hello"
}

output "url" {
  value = "${trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")}/hello"
}

output "function_name" {
  value = aws_lambda_function.this.function_name
}