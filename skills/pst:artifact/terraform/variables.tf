variable "domain" {
  description = "Full subdomain the site is served at, e.g. \"artifacts.pstaylor.net\". Also used as the default S3 bucket name."
  type        = string
}

variable "hosted_zone_name" {
  description = "Apex of the existing Route53 public hosted zone, e.g. \"pstaylor.net\". The zone is looked up (not created) and must already exist."
  type        = string
}

variable "aws_profile" {
  description = "Named AWS CLI/credentials profile used by both the primary and us-east-1 providers."
  type        = string
}

variable "aws_region" {
  description = "Primary AWS region for the S3 bucket and non-CloudFront resources. CloudFront and its ACM certificate are always created in us-east-1."
  type        = string
  default     = "us-east-1"
}

variable "price_class" {
  description = "CloudFront price class controlling which edge locations serve the distribution. PriceClass_100 (US/Canada/Europe) is the cheapest."
  type        = string
  default     = "PriceClass_100"
}

variable "tags" {
  description = "Tags applied to taggable resources (CloudFront distribution, ACM certificate, S3 bucket)."
  type        = map(string)
  default     = {}
}
