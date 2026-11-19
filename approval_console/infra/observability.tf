resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# One alarm: any Lambda error in five minutes. A crash before the transaction
# commits is the case worth hearing about; rejects are normal responses, not
# errors.
resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "${local.name}-errors"
  alarm_description   = "The approval console function returned an error."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.console.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# The function URL is public, so unauthenticated traffic can add Lambda and log
# cost. This budget alerts; it cannot stop spend. The stop is
# `reserved_concurrency = 0` (README).
resource "aws_budgets_budget" "console" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Budgets want "user:<key>$<value>"; format() avoids HCL reading "$" plus an
  # interpolation as an escape (see account/infra/cost.tf).
  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:Project$%s", "changefabric-approval-console")]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
