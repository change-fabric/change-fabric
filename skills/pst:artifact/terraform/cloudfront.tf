# AWS-managed CachingOptimized cache policy (compresses, long TTLs, no cookies).
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

# Response headers applied to EVERY response. The platform is no-index by
# default, so X-Robots-Tag is the load-bearing header here; the rest are
# baseline security hardening.
resource "aws_cloudfront_response_headers_policy" "artifacts" {
  name    = "${replace(var.domain, ".", "-")}-security-headers"
  comment = "No-index + security headers for ${var.domain}"

  custom_headers_config {
    items {
      header   = "X-Robots-Tag"
      value    = "noindex, nofollow"
      override = true
    }
  }

  security_headers_config {
    content_type_options {
      override = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }
  }
}

# Viewer-request function: stable-id/cosmetic-slug routing + directory indexing.
resource "aws_cloudfront_function" "router" {
  name    = "${replace(var.domain, ".", "-")}-router"
  runtime = "cloudfront-js-2.0"
  comment = "Artifact permalink routing for ${var.domain}"
  publish = true
  code    = file("${path.module}/cloudfront_function.js")
}

resource "aws_cloudfront_distribution" "artifacts" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = var.domain
  default_root_object = "index.html"
  price_class         = var.price_class
  aliases             = [var.domain]

  origin {
    origin_id                = "s3-${aws_s3_bucket.artifacts.id}"
    domain_name              = aws_s3_bucket.artifacts.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.artifacts.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-${aws_s3_bucket.artifacts.id}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.artifacts.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.router.arn
    }
  }

  # Serve the real 404 page with a 404 status (not a 200 soft-404).
  custom_error_response {
    error_code         = 403
    response_code      = 404
    response_page_path = "/404.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 404
    response_page_path = "/404.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.artifacts.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = var.tags
}
