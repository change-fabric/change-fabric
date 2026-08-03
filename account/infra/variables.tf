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
  description = "Absolute dollar impact a Cost Explorer anomaly must reach before it is mailed. Low enough that a forgotten instance surfaces within a day, high enough that normal daily variance on a bill this size does not."
  type        = number
  default     = 15
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
