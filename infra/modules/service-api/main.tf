# One region's API for a service: an HTTP API plus any number of Lambda functions, each with its own routes,
# and an optional Lambda authorizer for protected routes.
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
  description = "Functions keyed by short name (e.g. read); each lists the HTTP routes it serves (none for an authorizer)"
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

variable "authorizer_function" {
  description = "Key (in functions) of the Lambda authorizer, or null for no authorizer"
  type        = string
  default     = null
}

variable "protected_routes" {
  description = "Routes that require a valid buyer token (checked by the authorizer)"
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.protected_routes) == 0 || var.authorizer_function != null
    error_message = "protected_routes needs an authorizer_function."
  }
}

variable "throttle_rate_limit" {
  description = "Default steady-state requests per second for each route"
  type        = number
}

variable "throttle_burst_limit" {
  description = "Default short burst of requests allowed above the steady rate"
  type        = number
}

variable "route_throttles" {
  description = "Per-route overrides of the default throttle, keyed by route (e.g. the hold route during a rush)"
  type = map(object({
    rate_limit  = number
    burst_limit = number
  }))
  default = {}
}

locals {
  # One entry per (function, route) pair, keyed by the route itself (e.g. "GET /events/{eventId}")
  routes = merge([
    for fn, cfg in var.functions : { for r in cfg.routes : r => fn }
  ]...)

  # Only functions that serve routes get an integration (the authorizer has none)
  routed_functions = { for k, v in var.functions : k => v if length(v.routes) > 0 }
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
  for_each               = local.routed_functions
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_function.fn[each.key].invoke_arn
  payload_format_version = "2.0"
}

# Checks the buyer token before a protected route runs. Results are cached per token for 60 s,
# so most requests don't even invoke the authorizer; no token at all -> 401 without invoking it.
resource "aws_apigatewayv2_authorizer" "this" {
  count                             = var.authorizer_function == null ? 0 : 1
  api_id                            = aws_apigatewayv2_api.this.id
  name                              = "${var.name}-authorizer"
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = aws_lambda_function.fn[var.authorizer_function].invoke_arn
  identity_sources                  = ["$request.header.Authorization"]
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true
  authorizer_result_ttl_in_seconds  = 60
}

resource "aws_apigatewayv2_route" "this" {
  #checkov:skip=CKV_AWS_309:Read routes and POST /session are public by design; buyer routes use the Lambda authorizer (authorization_type CUSTOM)
  for_each           = local.routes
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.fn[each.value].id}"
  authorization_type = contains(var.protected_routes, each.key) ? "CUSTOM" : "NONE"
  authorizer_id      = contains(var.protected_routes, each.key) ? aws_apigatewayv2_authorizer.this[0].id : null
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit
  }

  # Per-route overrides (a route must exist before it can have settings, hence depends_on below)
  dynamic "route_settings" {
    for_each = var.route_throttles
    content {
      route_key              = route_settings.key
      throttling_rate_limit  = route_settings.value.rate_limit
      throttling_burst_limit = route_settings.value.burst_limit
    }
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
      authError = "$context.authorizer.error"
    })
  }

  depends_on = [aws_apigatewayv2_route.this]
}

# Each function may be invoked only by THIS API (routes and the authorizer)
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