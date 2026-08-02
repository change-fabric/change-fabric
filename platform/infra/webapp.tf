# ---------------------------------------------------------------------------
# The staging web app: app.staging.changefabric.org.
#
# A private S3 bucket holding the built SPA, read only by CloudFront through an
# origin access control, on phase 1's wildcard certificate, with one alias record
# in the existing zone. Structurally this is site/infra/main.tf; the differences
# are all deliberate and are noted where they occur.
#
# Two of those differences carry the design:
#
# 1. This distribution has a SECOND origin, the phase 2 API Gateway custom
#    domain, behind /api/* and /v1/*. The app is therefore same-origin with its
#    own API. That is not a preference, it is the only shape that works behind a
#    shared Basic Auth gate: a browser replays Basic credentials only to the
#    origin that challenged it, so a cross-origin call from this host to
#    api.staging arrives with no Authorization header and the API's own gate
#    rejects it. Shipping the staging credential inside the JavaScript bundle
#    would be the alternative, and it is worse than the problem. Same-origin also
#    removes the CORS preflight, which the API cannot answer: it registers GET
#    and POST only, and a preflight never carries credentials to get past the
#    gate in the first place. See platform/web/src/config.ts.
#
# 2. A viewer-request CloudFront Function applies the staging Basic Auth gate at
#    the edge, before the S3 origin is considered. A CloudFront Function has no
#    network access at all, so it cannot read SSM per request. It therefore holds
#    only a SHA-256 digest of the expected Authorization header, compiled in at
#    deploy time by platform/web/deploy.sh from the SSM parameter. The function's
#    source in this repo carries a placeholder and nothing else; the published
#    function exists only in AWS. This is the estate-wide convention, set by the
#    per-team artifact function that the artifacts service has since replaced.
#
# Terraform does not manage the function's code for the same reason: putting the
# digest in Terraform would put it in the state file and in every plan output.
# The function is created and published by the deploy script, and referenced here
# by a data source.
# ---------------------------------------------------------------------------

locals {
  app_domain      = "app.staging.${var.domain}"
  app_bucket      = "changefabric-platform-app-staging"
  app_auth_fn     = "${local.name_prefix}-app-staging-basic-auth"
  api_origin_host = aws_apigatewayv2_domain_name.api.domain_name
}

# ---------------------------------------------------------------------------
# The bucket. Private, OAC-only, no public access of any kind.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "app" {
  bucket = local.app_bucket

  tags = merge(local.tags, { Name = local.app_bucket })
}

resource "aws_s3_bucket_public_access_block" "app" {
  bucket                  = aws_s3_bucket.app.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app" {
  bucket = aws_s3_bucket.app.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "app" {
  bucket = aws_s3_bucket.app.id

  # A deploy syncs with --delete, so a bad build overwrites the good one. Keeping
  # versions makes the previous build recoverable without a rebuild.
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_policy" "app" {
  bucket = aws_s3_bucket.app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontRead"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.app.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.app.arn
        }
      }
    }]
  })
}

# ---------------------------------------------------------------------------
# The distribution.
# ---------------------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "app" {
  name                              = "${local.name_prefix}-app-staging-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# The Basic Auth function is created and published by platform/web/deploy.sh,
# which is the only thing that ever holds the digest. Reading it here rather than
# managing it keeps the digest out of Terraform state and out of every plan.
data "aws_cloudfront_function" "app_basic_auth" {
  name  = local.app_auth_fn
  stage = "LIVE"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

# Forwards everything the API needs and nothing it does not: all viewer headers
# except Host (the API Gateway custom domain has to see its own host to route),
# all cookies (the session), and all query strings.
data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_distribution" "app" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = [local.app_domain]
  comment             = "change-fabric staging web app"
  price_class         = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.app.bucket_regional_domain_name
    origin_id                = "app-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.app.id
  }

  origin {
    domain_name = local.api_origin_host
    origin_id   = "platform-api"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "app-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
    compress               = true

    function_association {
      event_type   = "viewer-request"
      function_arn = data.aws_cloudfront_function.app_basic_auth.arn
    }
  }

  # The API. Never cached, every method allowed, and gated by the same function
  # so the whole surface is behind one credential rather than two.
  dynamic "ordered_cache_behavior" {
    # A list, not a set: ordered_cache_behavior is order-sensitive, and a set
    # has no order for Terraform to keep stable between plans.
    for_each = ["/api/*", "/v1/*"]

    content {
      path_pattern             = ordered_cache_behavior.value
      target_origin_id         = "platform-api"
      viewer_protocol_policy   = "https-only"
      allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods           = ["GET", "HEAD"]
      cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
      origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
      compress                 = true

      function_association {
        event_type   = "viewer-request"
        function_arn = data.aws_cloudfront_function.app_basic_auth.arn
      }
    }
  }

  # Client-routed SPA routing lives in the viewer-request function
  # (platform/web/basic-auth.function.js), which rewrites an extensionless,
  # non-API path to /index.html.
  #
  # There is deliberately no custom_error_response here. It used to map 403 and
  # 404 to /index.html with a 200, which is the usual recipe for a SPA on S3 and
  # OAC. It cannot work on THIS distribution, because the same distribution also
  # fronts the API: a custom_error_response is distribution-wide, so a genuine
  # 403 from an authorization check or a 404 from an unknown id was rewritten
  # into a 200 carrying an HTML page, and the app saw an unparseable body instead
  # of the reason the API gave. Rewriting in the function instead is scoped to
  # the paths that S3 serves.

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.staging.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = merge(local.tags, { Name = local.app_domain })
}

# ---------------------------------------------------------------------------
# DNS. One record, in the zone site/infra owns and this root only reads.
# ---------------------------------------------------------------------------

resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = local.app_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.app.domain_name
    zone_id                = aws_cloudfront_distribution.app.hosted_zone_id
    evaluate_target_health = false
  }
}

# ---------------------------------------------------------------------------
# The CI deploy role, modelled on site/infra/oidc.tf.
#
# Nothing assumes it yet: this phase deploys by running platform/web/deploy.sh
# with a human's credentials. The role is created now anyway, because the shape
# of the trust policy is the part that is easy to get subtly wrong later, and
# because a workflow that wants it should find it already correct rather than
# inventing its own. Wiring the workflow itself is deliberately not part of this
# phase.
# ---------------------------------------------------------------------------

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "deploy_app_trust" {
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

    # Both sub shapes, for the same reason site/infra/oidc.tf carries both: this
    # repo predates 2026-07-15, so it switches to the immutable
    # owner@ownerId/repo@repoId form on its next rename or transfer.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:change-fabric/change-fabric:ref:refs/heads/main",
        "repo:change-fabric@*/change-fabric@*:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "deploy_app" {
  name               = "${local.name_prefix}-app-staging-deploy"
  assume_role_policy = data.aws_iam_policy_document.deploy_app_trust.json

  tags = local.tags
}

data "aws_iam_policy_document" "deploy_app_permissions" {
  statement {
    sid       = "SyncAppBucket"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.app.arn, "${aws_s3_bucket.app.arn}/*"]
  }

  statement {
    sid       = "InvalidateDistribution"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = [aws_cloudfront_distribution.app.arn]
  }

  # Republishing the Basic Auth function is part of a deploy, because the digest
  # is compiled in at deploy time rather than stored anywhere.
  statement {
    sid       = "PublishBasicAuthFunction"
    effect    = "Allow"
    actions   = ["cloudfront:DescribeFunction", "cloudfront:GetFunction", "cloudfront:UpdateFunction", "cloudfront:PublishFunction"]
    resources = ["arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:function/${local.app_auth_fn}"]
  }

  statement {
    sid       = "ReadBasicAuthCredential"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:us-east-1:${data.aws_caller_identity.current.account_id}:parameter${local.staging_basic_auth_param}"]
  }

  statement {
    sid       = "DecryptBasicAuthCredential"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_key.ssm.arn]
  }
}

resource "aws_iam_role_policy" "deploy_app" {
  name   = "${local.name_prefix}-app-staging-deploy"
  role   = aws_iam_role.deploy_app.id
  policy = data.aws_iam_policy_document.deploy_app_permissions.json
}
