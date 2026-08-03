# ---------------------------------------------------------------------------
# Alarms on user-impacting symptoms.
#
# Before this file the account held one CloudWatch alarm, pay-app-5xx, belonging
# to an unrelated workload. The shared Postgres instance that every environment of
# the platform depends on had none. Neither API had one. No Lambda had one. No
# CloudFront distribution had one, including the two serving the production
# marketing site. A failure in any of them was discoverable only by someone
# happening to look.
#
# Every alarm here watches a symptom a user or an operator would feel, not a
# resource-utilisation curve for its own sake, and every one of them routes to the
# single SNS topic in alerts.tf.
#
# All of them reference resources OTHER roots own, by identifier, and create
# nothing those roots manage. That is what makes this root safe to apply while
# work is in flight on the others.
# ---------------------------------------------------------------------------

locals {
  alarm_actions = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------------------
# The shared Postgres instance. Single-AZ by design, deletion-protected,
# encrypted, private. Single-AZ means an AZ event is a real outage rather than a
# failover, which raises rather than lowers the value of knowing promptly.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "cf-platform-rds-cpu-high"
  alarm_description   = "Shared Postgres instance has been above 85 percent CPU for 15 minutes. On a db.t4g.small this is also the shape of burst-credit exhaustion, which degrades every environment at once."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = var.db_instance_identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
  tags          = local.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "cf-platform-rds-storage-low"
  alarm_description   = "Shared Postgres instance is under 2 GB of free storage. Storage autoscaling is on up to 100 GB, so this firing means autoscaling is not keeping up or has stopped, which ends in a read-only instance."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = var.db_instance_identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2 * 1024 * 1024 * 1024
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
  tags          = local.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_memory" {
  alarm_name          = "cf-platform-rds-memory-low"
  alarm_description   = "Shared Postgres instance is under 200 MB freeable memory. On a 2 GB instance this precedes swapping and then the OOM killer taking Postgres with it."
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  dimensions          = { DBInstanceIdentifier = var.db_instance_identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 200 * 1024 * 1024
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
  tags          = local.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "cf-platform-rds-connections-high"
  alarm_description   = "Shared Postgres instance is holding more than 150 connections. A db.t4g.small allows roughly 225, and Lambda scaling is the one thing here that can reach that ceiling without warning."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  dimensions          = { DBInstanceIdentifier = var.db_instance_identifier }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 150
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
  tags          = local.tags
}

# ---------------------------------------------------------------------------
# Lambdas, across all three roots.
#
# treat_missing_data is notBreaching everywhere below because most of these
# functions are genuinely idle for long stretches; "no invocations" is a normal
# state here and must not read as a fault.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = var.lambda_functions

  alarm_name          = "${each.value}-errors"
  alarm_description   = "${each.value} returned at least one error in a 5 minute window. These functions are low volume enough that a single error is worth a mail rather than a rate threshold that would need traffic to be meaningful."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
  tags          = local.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  for_each = var.lambda_functions

  alarm_name          = "${each.value}-throttles"
  alarm_description   = "${each.value} was throttled. No function in this account sets reserved concurrency, so a throttle means the account-wide concurrency pool is exhausted and every other function is being starved at the same time."
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
  tags          = local.tags
}

# ---------------------------------------------------------------------------
# The two HTTP APIs. A 5xx here is the server's own fault by definition, which is
# what makes it worth waking someone for; 4xx is a caller's problem and is not
# alarmed.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  for_each = var.http_apis

  alarm_name          = "cf-${each.key}-5xx"
  alarm_description   = "API ${each.value} (${each.key}) returned server errors. Includes the case where the integration Lambda never answered, which is how a missing VPC path to an AWS service presents from outside."
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = { ApiId = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
  tags          = local.tags
}

# ---------------------------------------------------------------------------
# CloudFront. A rate rather than a count, because these distributions serve every
# static asset on a page and a single 5xx during a deploy is noise.
#
# CloudFront publishes metrics only to us-east-1 and only under the Global region
# dimension, which is why this root has no second provider and why the dimension
# below is literal.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "cloudfront_5xx" {
  for_each = var.cloudfront_distributions

  alarm_name          = "cf-${each.key}-5xx-rate"
  alarm_description   = "Distribution ${each.value} (${each.key}) is serving more than 5 percent 5xx over 10 minutes. For the two site distributions this is the production marketing site being visibly broken."
  namespace           = "AWS/CloudFront"
  metric_name         = "5xxErrorRate"
  dimensions          = { DistributionId = each.value, Region = "Global" }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
  tags          = local.tags
}

# ---------------------------------------------------------------------------
# The one alarm that is not an AWS-internal metric.
#
# Every alarm above reads a number AWS publishes about its own service. This one
# is a request made from outside AWS, from several regions, against the real
# production hostname over real TLS, and it therefore catches the failure classes
# the others structurally cannot: an expired certificate, a broken DNS record, an
# origin that returns 200 with an empty body, a distribution disabled by mistake.
#
# It bills at roughly $1.50 a month (a health check plus the HTTPS option). That
# is the entire recurring cost this root adds beyond CloudTrail's S3 storage, and
# it buys the only outside-in signal the estate has.
# ---------------------------------------------------------------------------

resource "aws_route53_health_check" "site" {
  fqdn              = var.site_health_check_fqdn
  type              = "HTTPS"
  port              = 443
  resource_path     = "/"
  failure_threshold = 3
  request_interval  = 30
  measure_latency   = false

  tags = merge(local.tags, { Name = var.site_health_check_fqdn })
}

resource "aws_cloudwatch_metric_alarm" "site_unreachable" {
  alarm_name          = "changefabric-site-unreachable"
  alarm_description   = "${var.site_health_check_fqdn} failed its outside-in HTTPS health check from a majority of Route53 checker regions. This is the production site being down for real visitors."
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  dimensions          = { HealthCheckId = aws_route53_health_check.site.id }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
  tags          = local.tags
}
