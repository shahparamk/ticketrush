# Phase 2 observability for the PRIMARY region (us-east-1), where every write happens.
#  - Dashboard: hold outcomes (from the handler's own logs, via Logs Insights), API traffic and
#    errors, Lambda throttles/concurrency, DynamoDB transaction conflicts, and alarm states.
#  - Alarms on AWS's built-in metrics. No notification target yet (an SNS topic comes in Phase 8),
#    so for now they show their state on the dashboard and in the console.
#
# Why Logs Insights instead of metric filters: Lambda's JSON log format wraps our JSON inside a
# "message" STRING, which metric filters can't parse; Logs Insights can (parse ... regex).

locals {
  obs_region        = "us-east-1"
  obs_api_id        = regex("^https://([^.]+)\\.", module.ticketing_primary.base_url)[0]
  obs_hold_fn       = "${local.ticketing_name}-hold"
  obs_authorizer_fn = "${local.ticketing_name}-authorizer"
  obs_seats_table   = aws_dynamodb_table.this["seats"].name
}

resource "aws_cloudwatch_metric_alarm" "hold_throttles" {
  alarm_name          = "${local.name}-hold-throttles"
  alarm_description   = "The hold Lambda is out of concurrency: buyers get 503s instead of answers (the API burst should stop this first)"
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = local.obs_hold_fn }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "hold_errors" {
  alarm_name          = "${local.name}-hold-errors"
  alarm_description   = "The hold Lambda crashed (it should always answer, even when DynamoDB says no)"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = local.obs_hold_fn }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "authorizer_errors" {
  alarm_name          = "${local.name}-authorizer-errors"
  alarm_description   = "The token authorizer crashed (it fails closed, so buyers are locked out)"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = local.obs_authorizer_fn }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${local.name}-ticketing-api-5xx"
  alarm_description   = "More than 10 server errors a minute on the ticketing API (primary region)"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = { ApiId = local.obs_api_id }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_dashboard" "phase2" {
  dashboard_name = "${local.name}-ticketing"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "text", x = 0, y = 0, width = 24, height = 2
        properties = {
          markdown = "# TicketRush: ticketing (primary, us-east-1)\nHolds are atomic DynamoDB transactions; the standby (us-west-2) refuses writes. **Oversold must always be 0.**"
        }
      },
      {
        type = "log", x = 0, y = 2, width = 8, height = 6
        properties = {
          title  = "Hold outcomes (from the handler's logs)"
          region = local.obs_region
          view   = "table"
          query  = "SOURCE '/aws/lambda/${local.obs_hold_fn}' | filter @message like /outcome/ | parse @message /outcome\\W+(?<outcome>[a-z_]+)/ | stats count(*) as requests by outcome | sort requests desc"
        }
      },
      {
        type = "metric", x = 8, y = 2, width = 8, height = 6
        properties = {
          title  = "API requests and errors (per minute)"
          region = local.obs_region
          stat   = "Sum"
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", local.obs_api_id, { label = "requests" }],
            [".", "4xx", ".", ".", { label = "4xx (incl. 409 taken, 429 throttled)" }],
            [".", "5xx", ".", ".", { label = "5xx" }],
          ]
        }
      },
      {
        type = "metric", x = 16, y = 2, width = 8, height = 6
        properties = {
          title  = "API latency (ms)"
          region = local.obs_region
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiId", local.obs_api_id, { stat = "p50", label = "p50" }],
            ["...", { stat = "p99", label = "p99" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 8, width = 8, height = 6
        properties = {
          title  = "Hold Lambda: invocations, throttles, errors"
          region = local.obs_region
          stat   = "Sum"
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", local.obs_hold_fn],
            [".", "Throttles", ".", "."],
            [".", "Errors", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 8, y = 8, width = 8, height = 6
        properties = {
          title  = "Concurrency in use (limit 200 each)"
          region = local.obs_region
          stat   = "Maximum"
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/Lambda", "ConcurrentExecutions", "FunctionName", local.obs_hold_fn, { label = "hold" }],
            ["...", local.obs_authorizer_fn, { label = "authorizer" }],
          ]
        }
      },
      {
        type = "metric", x = 16, y = 8, width = 8, height = 6
        properties = {
          title  = "Seats table: transaction conflicts and writes"
          region = local.obs_region
          stat   = "Sum"
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/DynamoDB", "TransactionConflict", "TableName", local.obs_seats_table, { label = "transaction conflicts" }],
            [".", "ConsumedWriteCapacityUnits", ".", ".", { label = "write units" }],
          ]
        }
      },
      {
        type = "alarm", x = 0, y = 14, width = 24, height = 3
        properties = {
          title = "Alarms"
          alarms = [
            aws_cloudwatch_metric_alarm.hold_throttles.arn,
            aws_cloudwatch_metric_alarm.hold_errors.arn,
            aws_cloudwatch_metric_alarm.authorizer_errors.arn,
            aws_cloudwatch_metric_alarm.api_5xx.arn,
          ]
        }
      },
    ]
  })
}

output "dashboard_url" {
  value = "https://${local.obs_region}.console.aws.amazon.com/cloudwatch/home?region=${local.obs_region}#dashboards/dashboard/${aws_cloudwatch_dashboard.phase2.dashboard_name}"
}