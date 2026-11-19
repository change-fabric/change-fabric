# ---------------------------------------------------------------------------
# Approval consumption for the bounded prod runner. A prod run records that it
# consumed an approval by writing one item here, from a GitHub Actions job, as a
# conditional put. The claim stops honest replays: the runner always sends
# attribute_not_exists(pk), so a second run for the same request is refused. It
# is not a lock against the role holder (see the LIMIT note on the role policy).
#
# Item shape (the contract the runner codes against):
#   pk          "CLAIM#<request_id>"   the approval's request id
#   sk          "CLAIM"
#   digest      the approval digest the run consumed
#   run_id      GitHub run id (string)
#   run_attempt GitHub run attempt (string)
#   claimed_at  ISO 8601 UTC
#   expires_at  epoch seconds, now + 30 days (TTL cleanup, long past approval TTL)
# The runner writes it with ConditionExpression "attribute_not_exists(pk)"; a failed condition
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

    # The repo's default immutable subject, matched exactly:
    # repo:<o>@<oid>/<r>@<rid>:environment:<env>
    # It pins the repo by owner and repo id and the GitHub Environment, whose
    # deployment rule (default branch only) is the branch pin. There is no
    # workflow-file pin: any default-branch workflow that runs in the
    # environment can claim. Accepted, because a stray claim only consumes an
    # approval, so the worst case is a blocked prod run (fails safe). Only sub
    # and aud are documented IAM condition keys for
    # token.actions.githubusercontent.com, so nothing else is relied on.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for repo in var.claim_repos : "repo:${repo}:environment:${var.claim_environment}"]
    }
  }
}

resource "aws_iam_role" "prod_claim" {
  name                 = "cf-prod-claim"
  assume_role_policy   = data.aws_iam_policy_document.claim_trust.json
  max_session_duration = 3600
}

# PutItem only, on CLAIM# keys only. No Get, Update or Delete, so the role can
# neither read nor delete a claim. LIMIT: IAM cannot require a condition
# expression, and an unconditional PutItem replaces an item. Immutability holds
# because the runner always sends attribute_not_exists(pk); a holder of this role
# could still overwrite a claim. A claim is evidence of consumption, not a lock
# the role cannot break.
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
