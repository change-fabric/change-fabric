# GitHub Actions authenticates to AWS via OIDC, not long-lived keys. The
# token.actions.githubusercontent.com provider already exists on this account
# (bootstrapped once, same reasoning as the Terraform state bucket in
# README.md); this only creates the role that trusts it, scoped to pushes on
# this repo's main branch so no other workflow or branch can assume it.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "deploy_site_trust" {
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

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:pstaylor-patrick/change-fabric:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "deploy_site" {
  name               = "changefabric-site-deploy"
  assume_role_policy = data.aws_iam_policy_document.deploy_site_trust.json
}

data "aws_iam_policy_document" "deploy_site_permissions" {
  statement {
    sid       = "SyncSiteBucket"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.site.arn, "${aws_s3_bucket.site.arn}/*"]
  }

  statement {
    sid       = "InvalidateDistributions"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = [aws_cloudfront_distribution.www.arn, aws_cloudfront_distribution.apex.arn]
  }
}

resource "aws_iam_role_policy" "deploy_site" {
  name   = "changefabric-site-deploy"
  role   = aws_iam_role.deploy_site.id
  policy = data.aws_iam_policy_document.deploy_site_permissions.json
}
