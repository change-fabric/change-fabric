terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # Zips the staged package directory (build.sh) at plan time.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # The same state bucket the other roots use, under this root's own key. The
  # bucket is bootstrapped once outside Terraform (see site/infra).
  backend "s3" {
    bucket = "changefabric-tfstate-569032832755"
    key    = "approval-console/terraform.tfstate"
    region = "us-east-1"
  }
}

# One us-east-1 provider serves the whole root: the function, its URL, the table,
# both keys, the budget and the alarm all live in one region.
provider "aws" {
  region  = "us-east-1"
  profile = var.aws_profile

  # The Project value joins this root to the account budget filter and the cost
  # allocation tags account/infra activates.
  default_tags {
    tags = {
      Project   = "changefabric-approval-console"
      ManagedBy = "terraform"
      Root      = "approval_console/infra"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  name = "cf-approval-console"

  # Seeds are encrypted by the CLI and decrypted only by the Lambda, and only
  # under an encryption context that names the machine. IAM and the key policy
  # both require the key, so a decrypt that omits it fails.
  context_key = "machine_id"

  # The function URL host is the WebAuthn rpId. Derived from the URL, never typed.
  rp_id = trimsuffix(trimprefix(aws_lambda_function_url.console.function_url, "https://"), "/")
}
