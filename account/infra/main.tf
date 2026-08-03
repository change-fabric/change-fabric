terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # The same backend bucket the site, telemetry and platform roots already use,
  # under a fourth key. This root owns nothing any of them own: it is deliberately
  # additive, so a plan here can never propose a change to a resource another root
  # manages, and an apply here can never race one of theirs.
  backend "s3" {
    bucket = "changefabric-tfstate-569032832755"
    key    = "changefabric-account/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = var.aws_profile
}

# us-east-1 is not a preference here, it is a requirement in three places at once.
# CloudFront publishes its metrics only to us-east-1, Route53 health checks publish
# their metrics only to us-east-1, and Cost Explorer and Budgets are global APIs
# that the provider reaches through us-east-1. Every alarm in this root reads one
# of those, so one provider covers the whole root.

locals {
  # Every workload this repository owns, by the Project tag its own root stamps.
  # These strings are the join between this root and the other three: the budget
  # filters on them, so a new root that forgets to tag its resources shows up as
  # untagged spend rather than silently inside somebody else's line item.
  project_tags = [
    "changefabric-platform",
    "changefabric-telemetry",
    "changefabric-site",
  ]

  tags = {
    Project   = "changefabric-account"
    ManagedBy = "terraform"
    Root      = "account/infra"
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
