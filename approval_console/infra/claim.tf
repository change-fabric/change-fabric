# ---------------------------------------------------------------------------
# Approval consumption for the bounded prod runner. A prod run records that it
# consumed an approval by writing one item here, from a GitHub Actions job, as a
# conditional put that can never overwrite or remove an earlier claim.
#
# Item shape (the contract the runner codes against):
#   pk          "CLAIM#<request_id>"   the approval's request id
#   sk          "CLAIM"
#   digest      the approval digest the run consumed
#   run_id      GitHub run id (string)
#   run_attempt GitHub run attempt (string)
#   claimed_at  ISO 8601 UTC
#   expires_at  epoch seconds, now + 30 days (TTL cleanup, long past approval TTL)
# Write it with ConditionExpression "attribute_not_exists(pk)"; a failed condition
# means the approval was already consumed.
# ---------------------------------------------------------------------------
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "claim_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Both subject shapes GitHub emits (see site/infra/oidc.tf), for the listed
    # repos only.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = flatten([
        for repo in var.claim_repos : [
          "repo:${repo}:*",
          "repo:${split("/", repo)[0]}@*/${split("/", repo)[1]}@*:*",
        ]
      ])
    }

    # The job must come from cf-prod.yml as it sits on the default branch, so a
    # branch or a fork cannot claim.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:workflow_ref"
      values   = [for repo in var.claim_repos : "${repo}/.github/workflows/cf-prod.yml@refs/heads/${var.claim_default_branch}"]
    }
  }
}

resource "aws_iam_role" "prod_claim" {
  name                 = "cf-prod-claim"
  assume_role_policy   = data.aws_iam_policy_document.claim_trust.json
  max_session_duration = 3600
}

# PutItem only, on CLAIM# keys only. No Get, Update or Delete, so the role can
# neither read nor rewrite a claim, and an overwrite is impossible because the
# put is conditional on the item not existing.
resource "aws_iam_role_policy" "prod_claim" {
  name = "claim-put"
  role = aws_iam_role.prod_claim.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ClaimPutOnly"
      Effect   = "Allow"
      Action   = "dynamodb:PutItem"
      Resource = aws_dynamodb_table.console.arn
      Condition = {
        "ForAllValues:StringLike" = { "dynamodb:LeadingKeys" = ["CLAIM#*"] }
      }
    }]
  })
}
