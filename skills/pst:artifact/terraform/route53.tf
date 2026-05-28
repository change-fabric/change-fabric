# Look up (do not create) the existing public hosted zone for the apex.
data "aws_route53_zone" "this" {
  name         = var.hosted_zone_name
  private_zone = false
}

# Fixed CloudFront hosted zone id (the same for every distribution, every region).
locals {
  cloudfront_hosted_zone_id = "Z2FDTNDATAQYW2"
}

resource "aws_route53_record" "a" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = var.domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.artifacts.domain_name
    zone_id                = local.cloudfront_hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "aaaa" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = var.domain
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.artifacts.domain_name
    zone_id                = local.cloudfront_hosted_zone_id
    evaluate_target_health = false
  }
}
