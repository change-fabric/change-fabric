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
