terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Zips the plain (non-container) Lambda build directories at plan time. The
    # container Lambdas (presence, notifications) skip this: they ship as ECR
    # images because their native ed25519 gem must be built against the runtime.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Remote state in the SAME backend bucket the site root already uses; only the
  # key differs, so telemetry gets its own isolated state file. The bucket is
  # bootstrapped once outside Terraform (see site/infra) and is reused as-is
  # here, so this root needs no new bootstrap step.
  backend "s3" {
    bucket = "changefabric-tfstate-569032832755"
    key    = "changefabric-telemetry/terraform.tfstate"
    region = "us-east-1"
  }
}

# One us-east-1 provider serves the whole config: the API Gateway custom domain,
# its regional ACM cert, DynamoDB, S3, and the Lambdas all live in one region,
# and it matches the account/region the site root already provisions into.
provider "aws" {
  region  = "us-east-1"
  profile = var.aws_profile
}

# Resource names and the handful of literal identifiers the plan pins (section 2,
# section 8). Kept in one place so every env var, ARN, and IAM statement below
# refers to the same strings instead of re-typing them.
locals {
  telemetry_table     = "cf-telemetry"
  presence_table      = "cf-presence"
  teams_table         = "cf-teams"
  notifications_table = "cf-notifications"
  transcripts_bucket  = "cf-transcripts"
  unscanned_index     = "gsi-unscanned"

  sweep_cursor_param = "/cf-secret-scan/cursor"
  api_secret_param   = "/cf-telemetry/api-secret"

  api_domain = "api.changefabric.org"

  # Every Ruby handler.rb exposes a top-level `handler(event:, context:)`, so the
  # Lambda handler string is uniform across the plain-zip functions.
  ruby_handler = "handler.handler"

  # Function names, pinned here so the IAM log-group scoping (iam.tf) and the
  # function resources (lambda.tf) always agree on the same string.
  fn = {
    transcript_ingest     = "cf-transcript-ingest"
    transcript_authorizer = "cf-transcript-authorizer"
    presence              = "cf-presence"
    secret_scanner        = "cf-secret-scanner"
    notifications         = "cf-notifications-api"
  }

  # Per-function CloudWatch Logs group ARN, the least-privilege scope for the
  # standard Logs statement every role carries.
  log_group_arns = {
    for key, name in local.fn :
    key => "arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${name}:*"
  }
}

data "aws_caller_identity" "current" {}

# The changefabric.org zone is owned by site/infra. We only READ its id to add
# records and validate the cert; we never manage the zone here, keeping the two
# roots free of any cross-state resource reference (section 7).
data "aws_route53_zone" "primary" {
  name         = var.domain
  private_zone = false
}

# The shared-secret for the transcript authorizer (Capability A) is seeded out of
# band as an SSM SecureString (see README) so it never lands in the repo. We read
# it at plan time and inject the plaintext into the authorizer's env only; the
# value lands in the encrypted remote state, nowhere else (section 8).
data "aws_ssm_parameter" "api_secret" {
  name            = local.api_secret_param
  with_decryption = true
}
