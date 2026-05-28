terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Primary provider. Used for the S3 bucket and any non-CloudFront/ACM resources.
provider "aws" {
  profile = var.aws_profile
  region  = var.aws_region
}

# CloudFront requires its ACM certificate to live in us-east-1, regardless of
# the region the rest of the stack is deployed to. This aliased provider pins
# the certificate (and its validation) to us-east-1 so the module stays correct
# even when var.aws_region points elsewhere.
provider "aws" {
  alias   = "us_east_1"
  profile = var.aws_profile
  region  = "us-east-1"
}
