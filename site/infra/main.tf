terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state in S3. The state bucket itself is bootstrapped once outside
  # Terraform (Terraform cannot create its own backend before it exists); see
  # README.md. Everything else in this config is a real Terraform resource.
  backend "s3" {
    bucket = "changefabric-tfstate-569032832755"
    key    = "changefabric-site/terraform.tfstate"
    region = "us-east-1"
  }
}

# CloudFront requires its ACM certificate in us-east-1, and the S3 bucket and
# Route53 records live here too, so one us-east-1 provider serves the whole
# config.
provider "aws" {
  region  = "us-east-1"
  profile = var.aws_profile

  # Every resource this root created was untagged, so the production marketing
  # site was invisible to any tag-based cost view, including the budget in
  # account/infra. These keys match the ones that root activates for cost
  # allocation and the ones platform/infra already stamps.
  default_tags {
    tags = {
      Project   = "changefabric-site"
      ManagedBy = "terraform"
      Root      = "site/infra"
    }
  }
}

locals {
  site_bucket = "changefabric-org-www-site"
}

# ---------------------------------------------------------------------------
# ACM certificate covering the apex and the www host, DNS-validated in Route53.
# ---------------------------------------------------------------------------

resource "aws_acm_certificate" "site" {
  domain_name               = var.domain
  subject_alternative_names = [var.www_domain]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for option in aws_acm_certificate.site.domain_validation_options :
    option.domain_name => {
      name   = option.resource_record_name
      type   = option.resource_record_type
      record = option.resource_record_value
    }
  }

  zone_id         = var.hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "site" {
  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# ---------------------------------------------------------------------------
# Private S3 bucket holding the built site, read only by CloudFront via OAC.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "site" {
  bucket = local.site_bucket
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# The deploy in deploy.sh is `aws s3 sync --delete` against the live production
# bucket. Without versioning, a bad build or a sync run from the wrong directory
# overwrites the site with no way back except rebuilding from whichever commit is
# believed to be good. With it, the previous objects are still there.
#
# The site is small and rebuilt from source on every release, so old versions have
# no long-term value; the lifecycle rule below keeps 30 days of undo and then
# stops paying for them.
resource "aws_s3_bucket_versioning" "site" {
  bucket = aws_s3_bucket.site.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    id     = "expire-old-site-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.site]
}

# The bucket already encrypts at rest with SSE-S3, because S3 has applied that by
# default to new objects since 2023. Declaring it makes the property explicit
# rather than inherited from an account default that could be changed elsewhere,
# and bucket keys cut the per-request encryption overhead. Not a CMK: the only
# reader is CloudFront through the OAC, the content is a public marketing site,
# and a CMK here would add a key policy to get right for no confidentiality gain.
resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontRead"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.site.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.www.arn
        }
      }
    }]
  })
}

# ---------------------------------------------------------------------------
# CloudFront: www serves the site; apex 301-redirects to www.
# ---------------------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "changefabric-site-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_function" "apex_redirect" {
  name    = "changefabric-apex-redirect"
  runtime = "cloudfront-js-2.0"
  comment = "301 apex to canonical www host"
  publish = true
  code    = file("${path.module}/redirect.js")
}

# Managed cache policy "CachingOptimized".
data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

# ---------------------------------------------------------------------------
# Security headers.
#
# Both distributions served the site with no security headers at all: no HSTS, no
# nosniff, no frame protection, no referrer policy. CloudFront applies these at
# the edge, so a static site on S3 gets them without an origin that can run code.
#
# include_subdomains is deliberately FALSE. HSTS with it on would bind every
# current and future subdomain of changefabric.org to HTTPS-only for a year, from
# a root that owns only the apex and www. api.changefabric.org and the staging
# hosts belong to other roots and are HTTPS-only today, so it would work, but
# committing them from here would be this root making a year-long promise on
# another root's behalf.
#
# preload is not set for the same reason, and because the preload list is
# effectively irreversible.
# ---------------------------------------------------------------------------

resource "aws_cloudfront_response_headers_policy" "site" {
  name    = "changefabric-site-security-headers"
  comment = "HSTS, nosniff, frame and referrer protection for the marketing site"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = false
      preload                    = false
      override                   = true
    }

    content_type_options {
      override = true
    }

    # The site has no reason to be framed by anyone.
    frame_options {
      frame_option = "DENY"
      override     = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
  }
}

resource "aws_cloudfront_distribution" "www" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = [var.www_domain]
  comment             = "changefabric.org canonical site"
  price_class         = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "site-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id       = "site-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
    compress               = true

    response_headers_policy_id = aws_cloudfront_response_headers_policy.site.id
  }

  # Single-page site: serve index.html for any not-found path.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

resource "aws_cloudfront_distribution" "apex" {
  enabled         = true
  is_ipv6_enabled = true
  aliases         = [var.domain]
  comment         = "changefabric.org apex redirect to www"
  price_class     = "PriceClass_100"

  # The origin is never read: the viewer-request function returns a 301 first.
  # It points at the same bucket only because a distribution requires an origin.
  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "site-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id       = "site-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id

    # The apex only ever answers with a redirect to www, but the redirect itself
    # is a response a browser acts on, so it carries the same headers.
    response_headers_policy_id = aws_cloudfront_response_headers_policy.site.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.apex_redirect.arn
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# ---------------------------------------------------------------------------
# Route53 alias records for both hosts in the existing hosted zone.
# ---------------------------------------------------------------------------

resource "aws_route53_record" "www" {
  zone_id = var.hosted_zone_id
  name    = var.www_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.www.domain_name
    zone_id                = aws_cloudfront_distribution.www.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "apex" {
  zone_id = var.hosted_zone_id
  name    = var.domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.apex.domain_name
    zone_id                = aws_cloudfront_distribution.apex.hosted_zone_id
    evaluate_target_health = false
  }
}
