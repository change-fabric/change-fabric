# No defaults on the two identity inputs: the profile is the deployer's own, and
# the alert address is where the deployer wants budget and error mail to land.
variable "aws_profile" {
  description = "AWS CLI profile used for provisioning, in the deployer's own account. No default."
  type        = string
}

variable "alert_email" {
  description = "Address that receives the budget alert and the Lambda error alarm. Confirm the SNS subscription mail after the first apply. No default."
  type        = string
}

variable "package_dir" {
  description = "Directory holding the staged Lambda package (handler, vendored shared files, gems). Built by build.sh. Zipped at plan time."
  type        = string
  default     = "build/package"
}

variable "monthly_budget_usd" {
  description = "Monthly cost ceiling for this root's tagged resources. The budget alerts at 80 percent actual and 100 percent forecast; it does not stop spend (README: set reserved concurrency to 0)."
  type        = number
  default     = 5
}

variable "reserved_concurrency" {
  description = "Reserved concurrency for the function. Bounds parallelism, not spend. Set 0 to stop the service. The account needs at least 10 unreserved executions left after this."
  type        = number
  default     = 5
}

variable "log_retention_days" {
  description = "Retention for the Lambda log group. The handler logs route, status and ids only."
  type        = number
  default     = 30
}

variable "dm_token_param" {
  description = "SSM SecureString name holding the DM bot token. Seeded out of band; the handler skips the DM when it is missing."
  type        = string
  default     = "/cf/approval-console/dm-token"
}

variable "dm_recipient_param" {
  description = "SSM String name holding the DM recipient id (the channel or user the bot messages). Seeded out of band."
  type        = string
  default     = "/cf/approval-console/dm-recipient"
}

variable "claim_repos" {
  description = "Consumer repos (OWNER/REPO) whose cf-prod.yml on the default branch may assume the cf-prod-claim role. No default: the role trusts exactly these."
  type        = list(string)

  validation {
    condition     = length(var.claim_repos) > 0 && alltrue([for r in var.claim_repos : can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", r))])
    error_message = "claim_repos must be a non-empty list of OWNER/REPO names."
  }
}

variable "claim_default_branch" {
  description = "The default branch the cf-prod.yml workflow_ref must be on."
  type        = string
  default     = "main"
}
