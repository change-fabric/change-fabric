# ---------------------------------------------------------------------------
# Cost visibility.
#
# The account already carried one budget, created by hand in the console years
# ago: a $20 monthly ceiling that July closed at $260.45 against, with four ACTUAL
# thresholds (25/50/75/100 percent) all sitting in ALARM. A budget that has been
# breached every month for years is not a control, it is a filtered mail rule, and
# it is why roughly $50 a month of staging spend accrued without anyone noticing.
# That budget stays where it is (it is not managed here, and adopting a
# hand-built resource into Terraform to immediately re-baseline it is a worse
# trade than leaving it alone); see README.md for the recommendation on it.
#
# What this file adds instead is two things that budget cannot do:
#
#   1. a ceiling scoped to just the workloads this repository owns, so the signal
#      is about changefabric and not about everything else sharing the account
#   2. anomaly detection, which needs no ceiling at all and is what actually
#      catches the failure mode that happened here, a large instance left running
#      after the day it was needed
# ---------------------------------------------------------------------------

# Cost Explorer ignores a resource tag until the tag key is activated for cost
# allocation. Every key the four roots stamp was Inactive, so the tags Terraform
# has been writing produced no cost visibility whatsoever and a tag-filtered
# budget would have matched nothing. Activation is not retroactive: it applies to
# usage from the activation month forward.
resource "aws_ce_cost_allocation_tag" "project" {
  tag_key = "Project"
  status  = "Active"
}

resource "aws_ce_cost_allocation_tag" "root" {
  tag_key = "Root"
  status  = "Active"
}

resource "aws_ce_cost_allocation_tag" "managed_by" {
  tag_key = "ManagedBy"
  status  = "Active"
}

resource "aws_ce_cost_allocation_tag" "env" {
  tag_key = "Env"
  status  = "Active"
}

# ---------------------------------------------------------------------------
# The changefabric ceiling.
#
# Both an ACTUAL and a FORECASTED threshold, which are different questions. ACTUAL
# says the month has already cost this much; FORECASTED says the current run rate
# ends the month over the line, which is the one that arrives while there is still
# something to do about it. The pre-existing console budget has only ACTUAL
# thresholds, so it can only ever report a fact after it is settled.
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "changefabric" {
  name         = "changefabric-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = [for project in local.project_tags : "user:Project$${project}"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
    subscriber_email_addresses = [var.alert_email]
  }

  depends_on = [
    aws_ce_cost_allocation_tag.project,
    aws_sns_topic_policy.alerts,
  ]
}

# ---------------------------------------------------------------------------
# Anomaly detection, account wide.
#
# A ceiling only fires when a total crosses a number somebody guessed in advance.
# This fires when one service's daily spend departs from its own learned baseline,
# whatever the total happens to be, which is the shape of every accident this
# account has actually had. It is free, and unlike the budget above it needs no
# tags to work, so it covers the untagged roots too.
# ---------------------------------------------------------------------------
resource "aws_ce_anomaly_monitor" "services" {
  name              = "changefabric-services"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"

  tags = local.tags
}

resource "aws_ce_anomaly_subscription" "services" {
  name      = "changefabric-anomalies"
  frequency = "DAILY"

  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  subscriber {
    type    = "EMAIL"
    address = var.alert_email
  }

  # Absolute dollars, not a percentage: a percentage threshold on a bill this
  # small alarms on rounding, and the thing worth knowing about is "something
  # started costing real money", which is a dollar amount.
  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_threshold_usd)]
    }
  }

  tags = local.tags
}
