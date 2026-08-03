# ---------------------------------------------------------------------------
# Two account-wide security controls that were absent, both free.
# ---------------------------------------------------------------------------

# `aws accessanalyzer list-analyzers` returned nothing, so no continuous check
# existed for a resource policy that grants access outside this account. The
# estate leans heavily on resource policies (the artifacts bucket, the site
# bucket's OAC grant, the KMS key policies, the SNS topic policy above, the VPC
# endpoint policies), and each of those is a place where a wildcard principal
# would be an account-crossing grant that no plan output would flag. IAM Access
# Analyzer evaluates them continuously and costs nothing.
#
# It reports findings; it does not block. Findings land in the Access Analyzer
# console and in Security Hub if that is ever turned on.
resource "aws_accessanalyzer_analyzer" "account" {
  analyzer_name = "changefabric-external-access"
  type          = "ACCOUNT"

  tags = local.tags
}

# `aws iam get-account-password-policy` returned NoSuchEntity: the account had no
# password policy, so IAM console passwords fell back to the AWS default minimum.
# The human here signs in through IAM Identity Center rather than an IAM user, so
# this policy governs a small surface, but three IAM users do exist in the account
# and the policy costs nothing to hold.
resource "aws_iam_account_password_policy" "account" {
  minimum_password_length        = 16
  require_uppercase_characters   = true
  require_lowercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true

  # No forced expiry. Rotation on a timer pushes people toward predictable
  # increments of one password rather than toward distinct strong ones, and the
  # control that actually matters here (no long-lived console password doing real
  # work at all) is a different fix, recorded in README.md under "Flagged, not
  # fixed".
  max_password_age          = 0
  password_reuse_prevention = 5
}

# ---------------------------------------------------------------------------
# Deliberately NOT here: an account-level S3 public access block.
#
# It is the obvious next control and it is the right one for an account dedicated
# to this estate. This account is not that. It is a shared personal account, and
# `aws s3api get-public-access-block --bucket pstaylor-public` returns all four
# flags false with no bucket policy, which is the signature of a bucket serving
# objects public by ACL. An account-level block would take that bucket offline
# instantly and silently, on behalf of a project that has nothing to do with this
# repository.
#
# Every bucket this repository owns already blocks public access at the bucket
# level, verified live: changefabric-artifacts-staging, changefabric-org-www-site,
# changefabric-platform-app-staging, changefabric-tfstate-569032832755 and
# cf-transcripts all return all four flags true. The account-level block is
# therefore an improvement in defence-in-depth against a future bucket, not a fix
# for a present exposure, and it is not worth breaking somebody else's site to get.
# It is written up in README.md as a flagged item for the account owner.
# ---------------------------------------------------------------------------
