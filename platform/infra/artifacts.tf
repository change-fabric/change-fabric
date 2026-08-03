# ---------------------------------------------------------------------------
# The staging artifacts host: artifacts.staging.changefabric.org.
#
# A private S3 bucket of published findings runs, served by CloudFront through an
# origin access control, on phase 1's wildcard certificate. Structurally this is
# webapp.tf. Three differences carry the design, and each is the reason a simpler
# arrangement was not used.
#
# 1. TWO gates, and TWO cache behaviors, because of the order CloudFront runs
#    them in.
#
#    The viewer-request function applies the same staging-wide Basic Auth digest
#    every other staging surface applies, compiled in at deploy time from the
#    same SSM parameter by platform/web/deploy-artifacts.sh. That gate answers
#    "does this request belong on staging at all", and it is identical in
#    mechanism to phases 2 and 3 on purpose: one credential, one algorithm, one
#    place to rotate.
#
#    Underneath it, `trusted_key_groups` makes CloudFront itself require a valid
#    signed cookie on every object request. That gate answers "may this person
#    read THIS team's files", and CloudFront enforces it natively against the
#    public key below. The API mints the cookies; it never proxies a byte.
#
#    CloudFront evaluates the key group BEFORE it invokes the function. That was
#    measured against this distribution rather than assumed: with both on one
#    behavior, an anonymous request is answered 403 by CloudFront and the
#    function never runs, so it can neither challenge for Basic Auth nor offer a
#    first-time visitor a way to obtain a cookie.
#
#    Hence the split, which is total rather than partial:
#
#      /v/*            the entry point. No key group, so the function runs. It
#                      serves NO bytes and never reaches the origin: every path
#                      through the function ends in a 401 or a 302. That is what
#                      makes the absence of a key group here harmless.
#      everything else the objects. Key group enforced on every request, with no
#                      exceptions and no list of file types to maintain.
#
#    Enumerating protected behaviors by file extension and leaving the default
#    unprotected was the alternative, and it was rejected: it protects the
#    extensions somebody remembered and serves the next one in the clear. Making
#    the catch-all the protected side means an unanticipated path fails closed.
#
#    The function does NOT verify the cookie, on either behavior. It cannot: a
#    CloudFront Function has no crypto beyond a hash and no way to hold a private
#    key. On the entry point it only notices whether the trio is present at all,
#    and forwards a request that has it to the real object path, where CloudFront
#    decides whether the cookie is genuine and unexpired. Distinguishing
#    "expired" from "forged" is exactly the judgement the native enforcement
#    exists to make.
#
# 2. SSE-KMS under the SHARED platform CMK, which is why kms.tf grew a statement.
#
#    CloudFront reads through an OAC as the `cloudfront.amazonaws.com` service
#    principal, which holds no IAM identity, so the key policy has to name it or
#    every object fetch fails to decrypt. That statement is in kms.tf, scoped to
#    this account and to requests arriving via S3.
#
# 3. Objects EXPIRE after 180 days. This is a real, data-destroying default and
#    it is stated in the PR description as one. A findings run is evidence about
#    a commit, and the commit it describes is long superseded by then; keeping
#    every run forever would grow without bound for no reader. Extending the
#    window is a one-line change here, but doing it after the fact does not bring
#    an expired object back.
#
# Terraform does not manage the function's code, for the same reason it does not
# manage the web app's: the digest would land in state and in every plan.
# ---------------------------------------------------------------------------

locals {
  artifacts_domain  = "artifacts.staging.${var.domain}"
  artifacts_bucket  = "changefabric-artifacts-staging"
  artifacts_auth_fn = "${local.name_prefix}-artifacts-staging-auth"

  # How long a published run survives. See the note above: this destroys data.
  artifacts_retention_days = 180

  staging_signer_key_param = "/cf-platform/staging/cloudfront-signer-private-key"
}

# ---------------------------------------------------------------------------
# The bucket.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "artifacts" {
  bucket = local.artifacts_bucket

  tags = merge(local.tags, { Name = local.artifacts_bucket })
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Bucket owner enforced, which disables ACLs entirely. Every object here arrives
# through a presigned PUT signed by the API's role, so there is never a second
# account whose ACL would need considering, and an ACL that cannot be set is an
# ACL that cannot accidentally publish something.
resource "aws_s3_bucket_ownership_controls" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# SSE-KMS under the shared platform CMK rather than SSE-S3, so the same key that
# protects the database's storage protects the findings that describe it, and so
# revoking the key revokes both at once. `bucket_key_enabled` collapses the
# per-object data key requests into one per bucket key period, which matters
# because a findings bundle is many small objects.
resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.platform.arn
    }
    bucket_key_enabled = true
  }
}

# Versioning is deliberately OFF, which is the opposite of the app bucket's
# choice and for a reason that does not apply there. The app bucket is synced
# with --delete on every deploy, so a bad build overwrites a good one and a
# previous version is the recovery path. Nothing here is ever overwritten: each
# run gets its own short id and therefore its own prefix, so a version history
# would record nothing except the incomplete uploads. It would also need its own
# noncurrent-version expiry to interact correctly with the rule below, which is a
# second retention policy to keep in agreement with the first.
resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  # THIS DELETES DATA. Every object published more than 180 days ago is removed,
  # whether or not anybody is still linking to it.
  rule {
    id     = "expire-published-runs"
    status = "Enabled"

    filter {}

    expiration {
      days = local.artifacts_retention_days
    }
  }

  # A presigned PUT that a client abandoned partway leaves parts that are billed
  # and unreachable. Seven days is well past any legitimate upload.
  rule {
    id     = "abort-abandoned-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.artifacts]
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontRead"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.artifacts.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.artifacts.arn
          }
        }
      },
      # Presigned URLs carry the SIGNER's authority, and the signer's requests
      # arrive over TLS like everything else. This says so out loud rather than
      # relying on it: a request that somehow arrived in the clear is refused
      # regardless of how well it was signed.
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# The signing key pair.
#
# Only the PUBLIC half is here, and only the public half is in this repository.
# The private half was generated locally with openssl and written straight to
# SSM with `aws ssm put-parameter`, so it has never been in a Terraform plan, a
# state file, or a commit. The API reads it once per cold start.
#
# Rotating it is: generate a new pair, put the private half in SSM, replace
# cloudfront-signer.pub.pem, apply (which adds the new public key to the key
# group), then redeploy the API. Adding before removing means no cookie already
# in a browser is invalidated mid-session.
# ---------------------------------------------------------------------------

resource "aws_cloudfront_public_key" "artifacts_signer" {
  name        = "${local.name_prefix}-artifacts-staging-signer"
  comment     = "Public half of the key the staging API signs artifact viewer cookies with"
  encoded_key = file("${path.module}/cloudfront-signer.pub.pem")

  # A public key cannot be updated in place, and it cannot be deleted while a
  # key group references it. Creating the replacement first is what makes a
  # rotation a rotation rather than an outage.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudfront_key_group" "artifacts_viewers" {
  name    = "${local.name_prefix}-artifacts-staging-viewers"
  comment = "Keys CloudFront accepts signed viewer cookies from for the staging artifacts host"
  items   = [aws_cloudfront_public_key.artifacts_signer.id]
}

# ---------------------------------------------------------------------------
# The distribution.
# ---------------------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "artifacts" {
  name                              = "${local.name_prefix}-artifacts-staging-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Created and published by platform/web/deploy-artifacts.sh, which is the only
# thing that ever holds the digest. Read here rather than managed, so the digest
# stays out of Terraform state and out of every plan. Same arrangement as the web
# app's function in webapp.tf.
data "aws_cloudfront_function" "artifacts_auth" {
  name  = local.artifacts_auth_fn
  stage = "LIVE"
}

resource "aws_cloudfront_distribution" "artifacts" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = [local.artifacts_domain]
  comment             = "change-fabric staging artifacts host"
  price_class         = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.artifacts.bucket_regional_domain_name
    origin_id                = "artifacts-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.artifacts.id
  }

  default_cache_behavior {
    target_origin_id       = "artifacts-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
    compress               = true

    # The real access control. CloudFront verifies the signed cookie against
    # this key group before it goes anywhere near the origin, on every object,
    # with no application code involved. The function above is a redirect for
    # convenience; this is the rule.
    trusted_key_groups = [aws_cloudfront_key_group.artifacts_viewers.id]

    function_association {
      event_type   = "viewer-request"
      function_arn = data.aws_cloudfront_function.artifacts_auth.arn
    }
  }

  # The entry point. Deliberately WITHOUT a key group, which is only safe
  # because the function returns a synthetic 401 or 302 for every request that
  # matches this pattern and never lets one reach the origin. Caching is
  # disabled for the same reason: every response here is a decision about the
  # request in front of it, and a cached 302 would be served to a viewer who has
  # since obtained cookies.
  ordered_cache_behavior {
    path_pattern           = "/v/*"
    target_origin_id       = "artifacts-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.disabled.id
    compress               = true

    function_association {
      event_type   = "viewer-request"
      function_arn = data.aws_cloudfront_function.artifacts_auth.arn
    }
  }

  # No custom_error_response, for the same reason webapp.tf has none: a 403 here
  # is a real answer (no valid cookie for that prefix) and a 404 is a real answer
  # (no such run), and rewriting either into a 200 carrying HTML would hide the
  # only two things a person needs to be told.

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

  tags = merge(local.tags, { Name = local.artifacts_domain })
}

# ---------------------------------------------------------------------------
# DNS. One record, in the zone site/infra owns and this root only reads.
# ---------------------------------------------------------------------------

resource "aws_route53_record" "artifacts" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = local.artifacts_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.artifacts.domain_name
    zone_id                = aws_cloudfront_distribution.artifacts.hosted_zone_id
    evaluate_target_health = false
  }
}
