# ---------------------------------------------------------------------------
# Standing interface endpoints for the API.
#
# The VPC has no internet gateway and no NAT, so every AWS API the Lambda calls
# needs a private path or the SDK simply hangs until its own timeout. Phase 1
# added one endpoint, for SES SMTP submission. Phase 2 needs two more, and both
# are gaps in phase 1 rather than new scope:
#
#   ssm    the function reads its secrets from SSM at cold start
#   email  the SES v2 API lives on email.<region>.amazonaws.com, which is a
#          different service from SMTP submission on email-smtp. The phase 1
#          endpoint does not carry SendEmail calls, only SMTP sessions.
#
# Both are single-AZ in us-east-1a, matching the cost posture phase 1 set for
# the SES SMTP endpoint: an interface endpoint bills per ENI per availability
# zone, and cross-AZ traffic inside the VPC reaches it from either subnet.
# ---------------------------------------------------------------------------

locals {
  platform_endpoint_services = toset([
    "com.amazonaws.us-east-1.ssm",
    "com.amazonaws.us-east-1.email",
  ])
}

resource "aws_vpc_endpoint" "platform" {
  for_each = local.platform_endpoint_services

  vpc_id            = aws_vpc.platform.id
  service_name      = each.value
  vpc_endpoint_type = "Interface"

  subnet_ids         = [aws_subnet.private["a"].id]
  security_group_ids = [aws_security_group.vpc_endpoint.id]

  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-${replace(each.value, "com.amazonaws.us-east-1.", "")}" })
}

# The bootstrap bastion also needs the ssm endpoint, and AWS refuses a second
# endpoint for the same service with private DNS in one VPC. The bastion's own
# group therefore reaches the standing endpoints through this rule, which comes
# and goes with the bastion rather than living on permanently.
resource "aws_vpc_security_group_ingress_rule" "vpce_from_bastion" {
  count = var.provision_bastion ? 1 : 0

  security_group_id            = aws_security_group.vpc_endpoint.id
  description                  = "HTTPS from the ephemeral bootstrap bastion, which shares the standing ssm endpoint."
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.bastion[0].id
}

resource "aws_vpc_security_group_egress_rule" "bastion_to_platform_endpoints" {
  count = var.provision_bastion ? 1 : 0

  security_group_id            = aws_security_group.bastion[0].id
  description                  = "HTTPS to the standing interface endpoints, which is where the ssm endpoint lives."
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.vpc_endpoint.id
}
