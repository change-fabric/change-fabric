# ---------------------------------------------------------------------------
# One VPC with two private subnets and NO internet path. There is no internet
# gateway and no NAT gateway by design: nothing in this VPC needs to originate
# traffic to the public internet, and adding a NAT would change both the
# recurring cost and the security posture. Anything that needs an AWS service
# reaches it through an interface VPC endpoint (see ses.tf).
# ---------------------------------------------------------------------------

resource "aws_vpc" "platform" {
  cidr_block = local.vpc_cidr

  # Both are required for interface VPC endpoints to resolve through their
  # private DNS names.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = local.name_prefix })
}

resource "aws_subnet" "private" {
  for_each = local.azs

  vpc_id            = aws_vpc.platform.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.name

  # Private by construction: no public IP, and the route table below has no
  # default route out.
  map_public_ip_on_launch = false

  tags = merge(local.tags, { Name = "${local.name_prefix}-private-${each.key}" })
}

# A single private route table shared by both subnets. It carries only the
# implicit local route for 10.40.0.0/16, so there is no path off the VPC.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.platform.id

  tags = merge(local.tags, { Name = "${local.name_prefix}-private" })
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# Security groups. No Lambda exists yet (phase 2 adds it), but the group does:
# the RDS rule and the endpoint rule are both written against it, so the later
# phases attach a function and get the right reachability without editing this
# root's rules.
# ---------------------------------------------------------------------------

resource "aws_security_group" "lambda" {
  name = "${local.name_prefix}-lambda"
  # EC2 rejects an apostrophe in a security group description, so the wording
  # here stays within the character set it accepts.
  description = "Egress-only group for platform Lambda workloads. No ingress: nothing dials a Lambda ENI directly."
  vpc_id      = aws_vpc.platform.id

  tags = merge(local.tags, { Name = "${local.name_prefix}-lambda" })
}

resource "aws_vpc_security_group_egress_rule" "lambda_all" {
  security_group_id = aws_security_group.lambda.id
  description       = "All egress. Constrained in practice by the absence of any internet route; the reachable set is the VPC and its interface endpoints."
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds"
  description = "Postgres group for the shared cf-platform instance. Ingress on 5432 from the Lambda group only."
  vpc_id      = aws_vpc.platform.id

  tags = merge(local.tags, { Name = "${local.name_prefix}-rds" })
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_lambda" {
  security_group_id            = aws_security_group.rds.id
  description                  = "Postgres from the platform Lambda group."
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.lambda.id
}

# The endpoint group fronts the interface endpoint's ENI. Interface endpoints
# terminate TLS on 443 regardless of the service's own protocol, so SES SMTP is
# reached over 443 on the endpoint ENI.
resource "aws_security_group" "vpc_endpoint" {
  name        = "${local.name_prefix}-vpce"
  description = "Interface VPC endpoint group. HTTPS ingress from the Lambda group only."
  vpc_id      = aws_vpc.platform.id

  tags = merge(local.tags, { Name = "${local.name_prefix}-vpce" })
}

resource "aws_vpc_security_group_ingress_rule" "vpce_from_lambda" {
  security_group_id            = aws_security_group.vpc_endpoint.id
  description                  = "HTTPS from the platform Lambda group."
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.lambda.id
}
