terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Generates the SSM SecureString values in-config so no secret is typed by a
    # human, pasted into a variable, or written to a file on disk. The generated
    # values live only in the encrypted remote state and in SSM.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    # Creates the Postgres-level objects (a database and a login role) INSIDE the
    # RDS instance. The AWS provider cannot do this: a database and a role are
    # Postgres catalog objects, not AWS API objects.
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "~> 1.22"
    }
  }

  # Remote state in the SAME backend bucket the site and telemetry roots already
  # use; only the key differs, so the platform gets its own isolated state file.
  # The bucket is bootstrapped once outside Terraform (see site/infra) and is
  # reused as-is here, so this root needs no new bootstrap step.
  backend "s3" {
    bucket = "changefabric-tfstate-569032832755"
    key    = "changefabric-platform/terraform.tfstate"
    region = "us-east-1"
  }
}

# One us-east-1 provider serves the whole config. CloudFront (added in a later
# phase) requires its ACM certificate in us-east-1 regardless of where the rest
# of the stack lives, and every other resource here is regional in us-east-1 too,
# so a single provider covers both needs.
provider "aws" {
  region  = "us-east-1"
  profile = var.aws_profile
}

# Resource names and the literal identifiers this root pins. Kept in one place so
# every SSM path, tag, and DNS name below refers to the same strings.
locals {
  name_prefix = "cf-platform"

  vpc_cidr = "10.40.0.0/16"

  # Two AZs. A DB subnet group requires subnets in at least two availability
  # zones even when the instance itself is single-AZ.
  azs = {
    a = { name = "us-east-1a", cidr = "10.40.1.0/24" }
    b = { name = "us-east-1b", cidr = "10.40.2.0/24" }
  }

  db_instance_identifier = "cf-platform"
  staging_database       = "cf_platform_staging"
  staging_role           = "cf_platform_staging_app"

  db_master_password_param  = "/cf-platform/db-master-password"
  staging_db_password_param = "/cf-platform/staging/db-password"
  staging_auth_secret_param = "/cf-platform/staging/better-auth-secret"
  staging_basic_auth_param  = "/cf-platform/staging/basic-auth-credential"

  # The staging-wide HTTP Basic Auth gate sits in front of every staging surface
  # (web app, API, artifacts host) on top of the real per-org auth. Phases 2, 3
  # and 5 read this parameter; this root only provisions it.
  staging_basic_auth_credential = "changefabric:changefabric"

  staging_wildcard = "*.staging.${var.domain}"

  tags = {
    Project   = "changefabric-platform"
    ManagedBy = "terraform"
    Root      = "platform/infra"
  }
}

data "aws_caller_identity" "current" {}

# The changefabric.org zone is owned by site/infra. We only READ its id to add
# the cert validation records; we never manage the zone here, and we touch no
# record site/infra or telemetry/infra already owns.
data "aws_route53_zone" "primary" {
  name         = var.domain
  private_zone = false
}
