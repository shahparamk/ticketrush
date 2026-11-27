# One region's API for a service: an HTTP API plus any number of Lambda functions, each with its own routes.
# Used once per region by envs/dev, so both regions are always identical.
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
  description = "Service name prefix, e.g. ticketrush-dev-ticketing"
  type        = string
}

variable "kms_key_arn" {
  description = "This region's copy of the multi-Region data key (logs + environment variables)"
  type        = string
}

variable "functions" {
  description = "Functions keyed by short name (e.g. read); each lists the HTTP routes it serves"
  type = map(object({
    zip_path             = string
    zip_hash             = string
    role_arn             = string
    routes               = list(string)
    environment          = map(string)
    memory_size          = number
    timeout              = number
    reserved_concurrency = number
  }))
}

variable "throttle_rate_limit" {
  description = "Steady-state requests per second allowed for the whole API"
  type        = number
}

variable "throttle_burst_limit" {
  description = "Short burst of requests allowed above the steady rate"
  type        = number
}

locals {
  # One entry per (function, route) pair, keyed by the route itself (e.g. "GET /events/{eventId}")
  routes = merge([
    for fn, cfg in var.functions : { for r in cfg.routes : r => fn }
  ]...)
}

resource "aws_cloudwatch_log_group" "fn" {
  #checkov:skip=CKV_AWS_338:30-day retention for a dev environment (cost); production would keep a year
  for_each          = var.functions
  name              = "/aws/lambda/${var.name}-${each.key}"
  retention_in_days = 30
  kms_key_id        = var.kms_key_arn
}

resource "aws_lambda_function" "fn" {
  #checkov:skip=CKV_AWS_116:Invoked synchronously by API Gateway; errors go back to the caller, so an async dead-letter queue doesn't apply
  #checkov:skip=CKV_AWS_117:No VPC needed (DynamoDB and KMS are reached over AWS's endpoints); a VPC would add NAT cost and cold-start time
  #checkov:skip=CKV_AWS_272:Code signing is a hardening item for later
  for_each                       = var.functions
  function_name                  = "${var.name}-${each.key}"
  role                           = each.value.role_arn
  runtime                        = "nodejs24.x"
  handler                        = "index.handler"
  architectures                  = ["arm64"]
  filename                       = each.value.zip_path
  source_code_hash               = each.value.zip_hash
  memory_size                    = each.value.memory_size
  timeout                        = each.value.timeout
  reserved_concurrent_executions = each.value.reserved_concurrency
  kms_key_arn                    = var.kms_key_arn

  environment {
    variables = each.value.environment
  }

  tracing_config {
    mode = "Active"
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.fn[each.key].name
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

resource "aws_apigatewayv2_integration" "fn" {
  for_each               = var.functions
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_function.fn[each.key].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "this" {
  #checkov:skip=CKV_AWS_309:Read routes are public by design; buyer authentication (KMS-signed tokens) is added to write routes in step 2b
  for_each  = local.routes
  api_id    = aws_apigatewayv2_api.this.id
  route_key = each.key
  target    = "integrations/${aws_apigatewayv2_integration.fn[each.value].id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId = "$context.requestId"
      ip        = "$context.identity.sourceIp"
      routeKey  = "$context.routeKey"
      status    = "$context.status"
      latencyMs = "$context.responseLatency"
      error     = "$context.integrationErrorMessage"
    })
  }
}

# Each function may be invoked only by THIS API
resource "aws_lambda_permission" "api" {
  for_each      = var.functions
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

output "base_url" {
  value = trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")
}