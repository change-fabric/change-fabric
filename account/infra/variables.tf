variable "aws_profile" {
  description = "Local AWS CLI profile used for plan and apply. Matches the other three roots."
  type        = string
  default     = "personal"
}

variable "alert_email" {
  description = "Address every alarm, budget threshold and cost anomaly is delivered to. AWS sends a confirmation mail on the first apply and the subscription stays PendingConfirmation until the link in it is clicked."
  type        = string
  default     = "patrick@pstaylor.net"
}

variable "monthly_budget_usd" {
  description = "Monthly ceiling for the three changefabric workloads combined, in USD. Not an account ceiling: the filter in budgets.tf narrows it to resources carrying one of local.project_tags, so unrelated spend in this shared personal account never moves it."
  type        = number
  default     = 75
}

variable "anomaly_threshold_usd" {
  description = "Absolute dollar impact a Cost Explorer anomaly must reach before it is mailed. Was $15, which is above the $8.10/day the aegis-sandbox instance burned, so the incident this root exists to catch sat below the threshold for its whole life. $5 is below any single resource worth knowing about and above daily noise on a bill this size."
  type        = number
  default     = 5
}

# ---------------------------------------------------------------------------
# Per-account ceilings.
#
# The one budget this root had was tag-filtered, which answers "what did
# changefabric cost" and not "which account is bleeding". The failure this
# exists to catch was an untagged hand-launched instance in the payer account,
# so the filter that would have caught it is LinkedAccount, not a tag: an
# account id is stamped by AWS and cannot be forgotten the way a tag can.
#
# Limits are measured steady-state run rate plus about 20 percent. That is
# deliberately tight. The payer account's spend is lumpy (roughly $8.16/mo
# accruing daily plus about $12.98 of Route53 hosted-zone charge landing on the
# 1st), so a FORECASTED threshold will occasionally fire early in the month on
# nothing. Tight-with-false-alarms was chosen over loose-and-silent.
# ---------------------------------------------------------------------------
variable "account_budgets" {
  description = "Monthly USD ceiling per linked account, keyed by a human label. The key names the budget; the account_id is the LinkedAccount cost filter."
  type = map(object({
    account_id = string
    limit_usd  = number
  }))

  default = {
    "payer" = {
      account_id = "569032832755"
      limit_usd  = 25
    }
    "j2j-production" = {
      account_id = "202689043194"
      limit_usd  = 42
    }
    "j2j-staging" = {
      account_id = "985823270538"
      limit_usd  = 54
    }
    "j2j-dns" = {
      account_id = "713407295108"
      limit_usd  = 5
    }
    "leagueos" = {
      account_id = "673586358710"
      limit_usd  = 5
    }
  }
}

# CloudFront distribution ids are literals rather than data-source lookups on
# purpose. There is no AWS data source that resolves a distribution by alias, and
# a cross-root remote_state read would couple this root's plan to another root's
# state file, which is exactly the coupling the separate-state decision above
# avoids. A distribution id is stable for the life of the distribution, and a
# stale id here fails loudly (the alarm reports INSUFFICIENT_DATA) rather than
# quietly watching the wrong thing.
variable "cloudfront_distributions" {
  description = "Distribution id keyed by a human label, for the 5xx alarms. Staging surfaces still under active construction are deliberately absent."
  type        = map(string)

  default = {
    "site-www"          = "E3BM1YJWLNRG4D"
    "site-apex"         = "E35B30BBUPC07K"
    "staging-app"       = "EM0OMLED50Q9E"
    "staging-artifacts" = "E1C6IQBS74A4EG"
  }
}

variable "lambda_functions" {
  description = "Every Lambda across the three roots that an error alarm should watch, by function name."
  type        = set(string)

  default = [
    "cf-platform-api",
    "cf-platform-migrate",
    "cf-transcript-ingest",
    "cf-transcript-authorizer",
    "cf-secret-scanner",
    "cf-presence",
    "cf-notifications-api",
  ]
}

variable "http_apis" {
  description = "API Gateway v2 API id keyed by a human label, for the 5xx alarms."
  type        = map(string)

  default = {
    "platform-api"  = "4hpctxuzj8"
    "telemetry-api" = "54tgvz7gwh"
  }
}

variable "db_instance_identifier" {
  description = "The shared Postgres instance platform/infra owns and this root only watches."
  type        = string
  default     = "cf-platform"
}

variable "site_health_check_fqdn" {
  description = "The production hostname the Route53 health check probes from outside AWS. This is the one alarm in this root that fires on what a real visitor experiences rather than on an internal metric."
  type        = string
  default     = "www.changefabric.org"
}
