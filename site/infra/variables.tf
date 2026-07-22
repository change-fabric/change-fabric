variable "aws_profile" {
  description = "AWS CLI profile used for provisioning (the personal account)."
  type        = string
  default     = "personal"
}

variable "domain" {
  description = "Apex domain."
  type        = string
  default     = "changefabric.org"
}

variable "www_domain" {
  description = "Canonical www hostname the site is served on."
  type        = string
  default     = "www.changefabric.org"
}

variable "hosted_zone_id" {
  description = "Existing Route53 public hosted zone id for the apex domain."
  type        = string
  default     = "Z085992826QJCTEIBCCHA"
}
