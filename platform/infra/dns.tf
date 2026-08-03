# ---------------------------------------------------------------------------
# One DNS-validated wildcard certificate covering every staging host:
# app.staging, api.staging and artifacts.staging all fall under
# *.staging.changefabric.org, so later phases need no new certificate.
#
# The cert is issued in us-east-1 because CloudFront (phase 5's artifacts host)
# accepts a certificate only from that region, regardless of where the rest of
# the distribution's resources live.
#
# The changefabric.org zone stays owned by site/infra: we only READ its id (data
# source in main.tf) and add validation records, exactly as site/infra and
# telemetry/infra already do.
# ---------------------------------------------------------------------------

resource "aws_acm_certificate" "staging" {
  domain_name       = local.staging_wildcard
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-staging" })
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for option in aws_acm_certificate.staging.domain_validation_options :
    option.domain_name => {
      name   = option.resource_record_name
      type   = option.resource_record_type
      record = option.resource_record_value
    }
  }

  zone_id = data.aws_route53_zone.primary.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60

  # A wildcard's validation record collides by name with the record an earlier
  # or re-created cert left behind. Overwriting is the documented handling and
  # matches site/infra and telemetry/infra.
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "staging" {
  certificate_arn         = aws_acm_certificate.staging.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}
