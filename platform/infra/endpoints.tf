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
#
# Phase 5 adds a third path, and it is a GATEWAY endpoint rather than an
# interface one. See below.
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

# ---------------------------------------------------------------------------
# S3, for the artifacts host.
#
# Presigning needs no network at all: it is a signature over a request the API
# never sends, which is why POST /v1/artifacts worked before this endpoint
# existed. What does need a network path is the ONE S3 call the API actually
# makes, the HeadObject in POST /v1/artifacts/:id/complete that compares an
# uploaded object against what the manifest declared. Without a path, that call
# does not fail: it hangs until the function's own timeout, and the caller sees
# a gateway error rather than anything about S3. That is exactly how it was
# found.
#
# A GATEWAY endpoint rather than an interface one, and the difference is not
# incidental. A gateway endpoint is a route in a route table, so it costs
# nothing per hour and nothing per gigabyte, and it needs no ENI, no security
# group and no AZ decision. The two interface endpoints above exist because SSM
# and the SES v2 API offer no gateway form; S3 does, so it gets the free one.
# It also keeps the VPC's central property intact: still no internet gateway,
# still no NAT, still no route to anywhere that is not an AWS service endpoint.
# ---------------------------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.platform.id
  service_name      = "com.amazonaws.us-east-1.s3"
  vpc_endpoint_type = "Gateway"

  # The one private route table both subnets associate with, so both reach S3.
  route_table_ids = [aws_route_table.private.id]

  # Narrowed to the artifacts bucket. The endpoint is a path, not a permission,
  # and the API's IAM role is what actually grants anything; this says that even
  # a mistake in that role cannot reach another bucket THROUGH THIS VPC.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ArtifactsBucketOnly"
      Effect    = "Allow"
      Principal = "*"
      Action    = ["s3:GetObject", "s3:PutObject"]
      Resource  = ["${aws_s3_bucket.artifacts.arn}/*"]
    }]
  })

  tags = merge(local.tags, { Name = "${local.name_prefix}-s3" })
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
