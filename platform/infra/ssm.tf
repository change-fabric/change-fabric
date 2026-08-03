# ---------------------------------------------------------------------------
# Secrets. Every value here is generated in-config by the random provider rather
# than typed by a human or passed in a variable, so no secret is ever written to
# a file on disk or printed by a plan. The generated values reach exactly two
# places: the encrypted S3 remote state, and SSM as SecureStrings under the
# account's default SSM key. None of them is an output of this root.
#
# A future re-provision from scratch can instead seed these by hand before
# applying; see README.md for that procedure.
# ---------------------------------------------------------------------------

# The RDS instance's own master password. Used ONLY by the postgresql provider
# to create the staging database and role. Application code never reads it.
# RDS rejects several punctuation characters in a master password, so the
# override_special set is narrowed to what it accepts.
resource "random_password" "db_master" {
  length           = 40
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_ssm_parameter" "db_master_password" {
  name        = local.db_master_password_param
  type        = "SecureString"
  value       = random_password.db_master.result
  description = "Master user password for the shared cf-platform RDS instance. Used only to administer the instance and to create per-environment databases and roles."

  tags = local.tags
}

# The staging application login role's password. This is what phase 2's Lambda
# actually connects with.
resource "random_password" "staging_app" {
  length           = 40
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_ssm_parameter" "staging_db_password" {
  name        = local.staging_db_password_param
  type        = "SecureString"
  value       = random_password.staging_app.result
  description = "Password for the staging application Postgres login role. Read by the staging API at runtime."

  tags = local.tags
}

# Better Auth session signing secret. Nothing reads it yet; phase 2 does. It is
# pure infrastructure, so it is provisioned now rather than left as a manual step
# for a later phase's implementer.
resource "random_password" "staging_better_auth" {
  length  = 48
  special = false
}

resource "aws_ssm_parameter" "staging_better_auth_secret" {
  name        = local.staging_auth_secret_param
  type        = "SecureString"
  value       = random_password.staging_better_auth.result
  description = "Better Auth session signing secret for staging. Consumed by the staging web app and API from phase 2 onward."

  tags = local.tags
}

# The staging-wide HTTP Basic Auth gate. This sits IN FRONT OF the real per-org
# authentication, not instead of it: it keeps the whole staging environment off
# the open internet while the product's own auth is being built. Phases 2, 3 and
# 5 apply it to the web app, the API, and the artifacts host respectively; all
# three read this one parameter so the credential stays in a single place.
#
# The value is a deliberate, non-secret shared credential (user:pass, colon
# separated), stored as a SecureString for uniformity with the parameters around
# it rather than because it is sensitive.
resource "aws_ssm_parameter" "staging_basic_auth_credential" {
  name        = local.staging_basic_auth_param
  type        = "SecureString"
  value       = local.staging_basic_auth_credential
  description = "Shared HTTP Basic Auth credential (user:pass) gating every staging surface. Consumed by phases 2 (web app), 3 (API) and 5 (artifacts)."

  tags = local.tags
}
