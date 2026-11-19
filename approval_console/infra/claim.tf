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

    # Both subject shapes GitHub emits (see site/infra/oidc.tf), for the listed
    # repos only. With claim_environment set the subject is pinned to that
    # GitHub Environment, whose own rules (default-branch only, reviewers) then
    # gate the job.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = flatten([
        for repo in var.claim_repos : [
          "repo:${repo}:${local.claim_subject_tail}",
          "repo:${split("/", repo)[0]}@*/${split("/", repo)[1]}@*:${local.claim_subject_tail}",
        ]
      ])
    }

    # AWS exposes only a fixed set of GitHub claims as condition keys, and
    # workflow_ref is not one of them. `ref` and `workflow` are: the job must run
    # on the default branch, in the workflow named claim_workflow_name. The name
    # is not a file path, so the Environment pin above is the stronger lock.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:ref"
      values   = ["refs/heads/${var.claim_default_branch}"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:workflow"
      values   = [var.claim_workflow_name]
    }
  }
}

locals {
  claim_subject_tail = var.claim_environment == "" ? "*" : "environment:${var.claim_environment}"
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
