output "alerts_topic_arn" {
  description = "The one SNS topic every alarm, budget threshold and cost anomaly in this account publishes to. Other roots may subscribe their own alarms to it rather than growing a second topic."
  value       = aws_sns_topic.alerts.arn
}

output "alerts_kms_key_arn" {
  description = "CMK encrypting the alerts topic. A new publisher that is an AWS service principal needs adding to this key's policy as well as the topic policy."
  value       = aws_kms_key.alerts.arn
}

output "alert_email_confirmation_required" {
  description = "Reminder that a green apply is not proof of delivery: the email subscription is PendingConfirmation until the link AWS mails is clicked."
  value       = "Confirm the SNS subscription mailed to ${var.alert_email} before treating any alarm here as delivered."
}

output "cloudtrail_name" {
  description = "The multi-region management-events trail."
  value       = aws_cloudtrail.management.name
}

output "cloudtrail_bucket" {
  description = "Where the trail lands. Objects expire after 365 days."
  value       = aws_s3_bucket.trail.id
}

output "budget_name" {
  description = "Monthly ceiling scoped by Project tag to the three changefabric workloads."
  value       = aws_budgets_budget.changefabric.name
}

output "site_health_check_id" {
  description = "Route53 health check behind the outside-in production alarm."
  value       = aws_route53_health_check.site.id
}

output "alarm_names" {
  description = "Every alarm this root creates, so a reviewer can compare the list against describe-alarms without reading the config."
  value = sort(concat(
    [
      aws_cloudwatch_metric_alarm.rds_cpu.alarm_name,
      aws_cloudwatch_metric_alarm.rds_storage.alarm_name,
      aws_cloudwatch_metric_alarm.rds_memory.alarm_name,
      aws_cloudwatch_metric_alarm.rds_connections.alarm_name,
      aws_cloudwatch_metric_alarm.site_unreachable.alarm_name,
    ],
    [for alarm in aws_cloudwatch_metric_alarm.lambda_errors : alarm.alarm_name],
    [for alarm in aws_cloudwatch_metric_alarm.lambda_throttles : alarm.alarm_name],
    [for alarm in aws_cloudwatch_metric_alarm.api_5xx : alarm.alarm_name],
    [for alarm in aws_cloudwatch_metric_alarm.cloudfront_5xx : alarm.alarm_name],
  ))
}
