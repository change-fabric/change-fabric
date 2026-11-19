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
  description = "Consumer repos whose cf-claim environment jobs may assume the cf-prod-claim role, each as OWNER@OWNER_ID/REPO@REPO_ID (the sub_claim_prefix from gh api repos/OWNER/REPO/actions/oidc/customization/sub, without repo:). No default: the role trusts exactly these."
  type        = list(string)

  validation {
    condition     = length(var.claim_repos) > 0 && alltrue([for r in var.claim_repos : can(regex("^[A-Za-z0-9_.-]+@[0-9]+/[A-Za-z0-9_.-]+@[0-9]+$", r))])
    error_message = "claim_repos must be a non-empty list of OWNER@OWNER_ID/REPO@REPO_ID immutable subject prefixes."
  }
}

variable "claim_environment" {
  description = "The dedicated GitHub Environment the claim job runs in (no required reviewers, deployment branch = default only); pinned into the exact OIDC subject and the branch pin. Must match the environment the generated cf-prod.yml claim job names."
  type        = string
  default     = "cf-claim"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+$", var.claim_environment))
    error_message = "claim_environment must be a non-empty name of letters, digits, _, . or - (it sits in a StringLike sub, so no wildcards)."
  }
}
