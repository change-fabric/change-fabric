# ACM certificate for the site domain. CloudFront only accepts certificates from
# us-east-1, so this (and its validation) use the aliased us_east_1 provider.
resource "aws_acm_certificate" "artifacts" {
  provider = aws.us_east_1

  domain_name       = var.domain
  validation_method = "DNS"

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# One Route53 validation record per domain validation option (just the apex here,
# but for_each keeps it correct if SANs are added later).
resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.artifacts.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.this.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# Blocks until the DNS records validate the certificate.
resource "aws_acm_certificate_validation" "artifacts" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.artifacts.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]
}
