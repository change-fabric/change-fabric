# SES SMTP reached from inside the VPC without any internet path. This is the
# reason the VPC can stay NAT-free: the only outbound dependency the platform
# has in this phase is transactional mail, and an interface endpoint serves it
# privately.
#
# Deliberately single-AZ (us-east-1a). An interface endpoint bills per ENI per
# AZ, so a second AZ roughly doubles the endpoint's cost for HA this staging
# posture does not yet need. Phase 8 revisits this alongside production.
resource "aws_vpc_endpoint" "email_smtp" {
  vpc_id            = aws_vpc.platform.id
  service_name      = "com.amazonaws.us-east-1.email-smtp"
  vpc_endpoint_type = "Interface"

  subnet_ids         = [aws_subnet.private["a"].id]
  security_group_ids = [aws_security_group.vpc_endpoint.id]

  # Resolves email-smtp.us-east-1.amazonaws.com to the endpoint ENI inside the
  # VPC, so a client needs no endpoint-specific hostname.
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-email-smtp" })
}
