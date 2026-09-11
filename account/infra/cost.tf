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

  # format() rather than a template string. The TagKeyValue format Budgets wants
  # is "user:<key>$<value>", and a literal dollar immediately before an
  # interpolation cannot be written inline: HCL scans "$$${project}" left to
  # right as a literal "$" followed by the ESCAPE "$${", yielding the literal
  # "$${project}" that AWS rejects with "is not comply with key-value format".
  # That is the bug this replaces. The budget shipped reading $0.00 against a
  # $75 limit for its whole life because its filter matched no tag at all.
  cost_filter {
    name   = "TagKeyValue"
    values = [for project in local.project_tags : format("user:Project$%s", project)]
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
  name = "changefabric-anomalies"

  # IMMEDIATE with a single SNS subscriber, which is the only shape Cost Explorer
  # allows here. Its rules are mutually exclusive and neither is documented in a
  # way you find before the API says it: a DAILY or WEEKLY subscription accepts
  # EMAIL subscribers only ("Daily or weekly frequencies only support Email
  # subscriptions"), and an IMMEDIATE one accepts at most one subscriber of any
  # kind ("Immediate frequencies support a max of one subscriber"). An EMAIL and
  # an SNS subscriber on the same subscription cannot be expressed at all.
  #
  # SNS wins the choice because it loses nothing. The cf-alerts topic already
  # carries a CONFIRMED email subscription to the same address, so the mail still
  # arrives; what routing through the topic adds is that every alert source in
  # this root now converges on one place, so a future second channel is one
  # subscription on one topic rather than an edit to every source. IMMEDIATE also
  # alerts sooner, which on a $5 absolute threshold is the difference between
  # catching a burn on its first day and on its second.
  frequency = "IMMEDIATE"

  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.alerts.arn
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

  depends_on = [aws_sns_topic_policy.alerts]
}

# ---------------------------------------------------------------------------
# Per-account ceilings.
#
# One budget per linked account, filtered on LinkedAccount. This is the
# guardrail chosen after the aegis-sandbox incident: a c6i.2xlarge tagged
# purpose=aegis-aws-sandbox-one-day ran for weeks at about $8.26/day. The tag
# was correct and nothing read it, so the control here reads the one dimension
# AWS stamps for you.
#
# Deliberately NOT here: a TTL-tag reaper. It was offered in both auto-stop and
# auto-terminate form and declined. The purpose/TTL tag convention stays a
# convention, unenforced, on purpose.
#
# Deliberately NOT here: the hand-built console "Monthly Budget" ($20, org
# wide, all four ACTUAL thresholds stuck in ALARM). It is duplicate noise
# against these, and re-baselining it is deferred until one clean billing
# cycle has passed and the real new run rate can be measured rather than
# guessed.
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "account" {
  for_each = var.account_budgets

  name         = "cf-account-${each.key}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(each.value.limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "LinkedAccount"
    values = [each.value.account_id]
  }

  # ACTUAL at 80 says the month is already most of the way gone. FORECASTED at
  # 100 says the current run rate ends the month over the line, which is the
  # one that arrives while there is still something to do about it.
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

  depends_on = [aws_sns_topic_policy.alerts]
}

# ---------------------------------------------------------------------------
# Anomaly detection, org wide.
#
# The existing DIMENSIONAL/SERVICE monitor watches each service against its own
# baseline, which is the right shape but was created 2026-08-03, weeks after the
# instance it would have caught had already launched. A burn that starts before
# the monitor exists becomes the baseline and is invisible forever after. This
# second monitor watches the linked accounts as a whole, so a new account or an
# untagged workload in an existing one is in scope from the day it appears.
#
# Corollary worth stating: create this BEFORE launching any new workload.
# Anomaly detection cannot retroactively learn what normal used to be.
# ---------------------------------------------------------------------------
# monitor_type is CUSTOM rather than DIMENSIONAL/LINKED_ACCOUNT because the
# pinned provider (hashicorp/aws ~> 5.0) validates monitor_dimension against a
# one-value list: "expected monitor_dimension to be one of [\"SERVICE\"], got
# LINKED_ACCOUNT". A CUSTOM monitor with a LINKED_ACCOUNT specification is the
# same coverage by a different door and is supported across the whole 5.x line.
# The account list is derived from var.account_budgets so the two controls
# cannot drift: an account added to the budgets is in the monitor by
# construction.
resource "aws_ce_anomaly_monitor" "accounts" {
  name         = "changefabric-accounts"
  monitor_type = "CUSTOM"

  # The null siblings are not noise. Cost Explorer echoes the specification back
  # with every unused branch of the expression present and null, so a config
  # carrying only Dimensions never matches the remote value and every plan
  # proposes replacing the monitor. Replacing it would be worse than cosmetic:
  # a new monitor relearns its baseline from zero and is blind while it does.
  monitor_specification = jsonencode({
    And            = null
    CostCategories = null
    Not            = null
    Or             = null
    Tags           = null

    Dimensions = {
      Key          = "LINKED_ACCOUNT"
      Values       = sort([for account in var.account_budgets : account.account_id])
      MatchOptions = ["EQUALS"]
    }
  })

  tags = local.tags
}

resource "aws_ce_anomaly_subscription" "accounts" {
  name = "changefabric-account-anomalies"

  # IMMEDIATE with a single SNS subscriber, which is the only shape Cost Explorer
  # allows here. Its rules are mutually exclusive and neither is documented in a
  # way you find before the API says it: a DAILY or WEEKLY subscription accepts
  # EMAIL subscribers only ("Daily or weekly frequencies only support Email
  # subscriptions"), and an IMMEDIATE one accepts at most one subscriber of any
  # kind ("Immediate frequencies support a max of one subscriber"). An EMAIL and
  # an SNS subscriber on the same subscription cannot be expressed at all.
  #
  # SNS wins the choice because it loses nothing. The cf-alerts topic already
  # carries a CONFIRMED email subscription to the same address, so the mail still
  # arrives; what routing through the topic adds is that every alert source in
  # this root now converges on one place, so a future second channel is one
  # subscription on one topic rather than an edit to every source. IMMEDIATE also
  # alerts sooner, which on a $5 absolute threshold is the difference between
  # catching a burn on its first day and on its second.
  frequency = "IMMEDIATE"

  monitor_arn_list = [aws_ce_anomaly_monitor.accounts.arn]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.alerts.arn
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_threshold_usd)]
    }
  }

  tags = local.tags

  depends_on = [aws_sns_topic_policy.alerts]
}
