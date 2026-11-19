# ---------------------------------------------------------------------------
# The production web app: app.changefabric.org.
#
# Staging's shape (webapp.tf) minus everything staging-only: a private S3 bucket
# read only by CloudFront through an origin access control, one DNS-validated
# certificate, one alias record, and the CI role deploy-app-prod.yml assumes.
#
# Deliberately absent, because production has none of it yet:
#
# - The Basic Auth viewer-request function. Production is public.
# - The /api/* and /v1/* origin. There is no production API; the staging API is
#   not reachable from here. The distribution is S3 only, so unlike staging it
#   can use a distribution-wide custom_error_response for SPA routing.
#
# Nothing in this file reads or touches staging state except the shared zone,
# the GitHub OIDC provider and the account id.
# ---------------------------------------------------------------------------

locals {
  app_prod_domain = "app.${var.domain}"
  app_prod_bucket = "changefabric-platform-app-prod"
}

resource "aws_s3_bucket" "app_prod" {
  bucket = local.app_prod_bucket

  tags = merge(local.tags, { Name = local.app_prod_bucket })
}

resource "aws_s3_bucket_public_access_block" "app_prod" {
  bucket                  = aws_s3_bucket.app_prod.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app_prod" {
  bucket = aws_s3_bucket.app_prod.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "app_prod" {
  bucket = aws_s3_bucket.app_prod.id

  # A deploy syncs with --delete; versions keep the previous release recoverable.
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_policy" "app_prod" {
  bucket = aws_s3_bucket.app_prod.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontRead"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.app_prod.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.app_prod.arn
        }
      }
    }]
  })
}

# ---------------------------------------------------------------------------
# Certificate. The staging certificate is *.staging.changefabric.org and does
# not cover app.changefabric.org, so production gets its own, in us-east-1 for
# CloudFront.
# ---------------------------------------------------------------------------

resource "aws_acm_certificate" "app_prod" {
  domain_name       = local.app_prod_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-app-prod" })
}

resource "aws_route53_record" "app_prod_cert_validation" {
  for_each = {
    for option in aws_acm_certificate.app_prod.domain_validation_options :
    option.domain_name => {
      name   = option.resource_record_name
      type   = option.resource_record_type
      record = option.resource_record_value
    }
  }

  zone_id         = data.aws_route53_zone.primary.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "app_prod" {
  certificate_arn         = aws_acm_certificate.app_prod.arn
  validation_record_fqdns = [for record in aws_route53_record.app_prod_cert_validation : record.fqdn]
}

# ---------------------------------------------------------------------------
# Distribution and DNS.
# ---------------------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "app_prod" {
  name                              = "${local.name_prefix}-app-prod-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "app_prod" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = [local.app_prod_domain]
  comment             = "change-fabric production web app"
  price_class         = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.app_prod.bucket_regional_domain_name
    origin_id                = "app-prod-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.app_prod.id
  }

  default_cache_behavior {
    target_origin_id       = "app-prod-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
    compress               = true
  }

  # Client-routed SPA. This distribution fronts only the bucket, so the usual
  # recipe is safe here: a private bucket answers 403 for a missing key, and
  # both that and 404 serve the shell. (Staging cannot do this; see webapp.tf.)
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.app_prod.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = merge(local.tags, { Name = local.app_prod_domain })
}

resource "aws_route53_record" "app_prod" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = local.app_prod_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.app_prod.domain_name
    zone_id                = aws_cloudfront_distribution.app_prod.hosted_zone_id
    evaluate_target_health = false
  }
}

# ---------------------------------------------------------------------------
# The CI deploy role for deploy-app-prod.yml.
#
# The workflow declares no environment:, so the sub's context is the ref, not
# environment:<name>. It runs on an app/v* tag push, so the sub is the id-pinned
# repo, that tag ref, and the workflow file at that same tag ref. StringLike is
# needed only for the two app/v* wildcards; aud stays an exact match.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "deploy_app_prod_trust" {
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
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:change-fabric@311455213/change-fabric@1180238677:ref:refs/tags/app/v*:job_workflow_ref:change-fabric/change-fabric/.github/workflows/deploy-app-prod.yml@refs/tags/app/v*",
      ]
    }
  }
}

resource "aws_iam_role" "deploy_app_prod" {
  name               = "${local.name_prefix}-app-prod-deploy"
  assume_role_policy = data.aws_iam_policy_document.deploy_app_prod_trust.json

  tags = local.tags
}

# Bucket sync and one invalidation, nothing else. No SSM, KMS or CloudFront
# function access: production has no Basic Auth gate to publish.
data "aws_iam_policy_document" "deploy_app_prod_permissions" {
  statement {
    sid       = "SyncAppBucket"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.app_prod.arn, "${aws_s3_bucket.app_prod.arn}/*"]
  }

  statement {
    sid       = "InvalidateDistribution"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = [aws_cloudfront_distribution.app_prod.arn]
  }
}

resource "aws_iam_role_policy" "deploy_app_prod" {
  name   = "${local.name_prefix}-app-prod-deploy"
  role   = aws_iam_role.deploy_app_prod.id
  policy = data.aws_iam_policy_document.deploy_app_prod_permissions.json
}
