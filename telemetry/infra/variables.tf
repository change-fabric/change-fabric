variable "aws_profile" {
  description = "AWS CLI profile used for provisioning (the personal account)."
  type        = string
  default     = "personal"
}

variable "domain" {
  description = "Apex domain whose existing Route53 hosted zone (owned by site/infra) is read to add the api.changefabric.org records."
  type        = string
  default     = "changefabric.org"
}

variable "log_retention_days" {
  description = "Retention for this root's Lambda and API access log groups. Matches platform/infra. Before this existed the groups were created implicitly by the Lambda service and kept everything forever."
  type        = number
  default     = 30
}

variable "throttle_rate_limit" {
  description = "Steady-state requests per second the API accepts across all routes. Three of four routes are unauthenticated at the gateway, so this is the only thing between an anonymous caller and the account-wide Lambda concurrency pool."
  type        = number
  default     = 50
}

variable "throttle_burst_limit" {
  description = "Burst capacity above throttle_rate_limit. Sized so a normal batch of session-end posts is never rejected."
  type        = number
  default     = 100
}

# The two container Lambdas ship as ECR images. Terraform provisions the empty
# repositories (ecr.tf) but cannot build or push the images, so their URIs have
# NO default: the deployer builds and pushes each image, then passes the pushed
# reference. Applying before the images exist fails on purpose, so a half-built
# backend never goes live.
variable "presence_image_uri" {
  description = "ECR image URI (<repo_url>:<tag> or @<digest>) for the presence Lambda. Set AFTER `docker build && docker push` to the cf-presence repo (see telemetry/infra/lambda/presence/README and the root README). No default: apply fails until a real pushed image is provided."
  type        = string
}

variable "notifications_image_uri" {
  description = "ECR image URI (<repo_url>:<tag> or @<digest>) for the notifications Lambda. Set AFTER `docker build && docker push` to the cf-notifications repo (see telemetry/infra/lambda/notifications/README and the root README). No default: apply fails until a real pushed image is provided."
  type        = string
}
