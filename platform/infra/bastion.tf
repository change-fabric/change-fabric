# ---------------------------------------------------------------------------
# Ephemeral bootstrap bastion.
#
# The shared Postgres instance is private on purpose, so nothing outside the VPC
# can reach 5432 to create a database or a role. This file stands up the
# smallest thing that closes that gap: one nano instance in a private subnet,
# reachable only through SSM Session Manager over interface endpoints, used as
# the far end of a port-forward while Terraform runs the postgresql provider.
#
# Everything here is gated on var.provision_bastion, default false. The bastion
# is created for one bootstrap run and destroyed immediately after; the database
# and role it creates live in RDS and outlive it. Phase 8 repeats exactly this
# procedure to add the production database.
#
# Session Manager works entirely over the three interface endpoints below, so
# this adds no internet gateway, no NAT, and no public IP.
# ---------------------------------------------------------------------------

# Amazon Linux 2023 on arm64, which ships the SSM agent enabled. Read from the
# public SSM parameter so the AMI id is never pinned to a stale build.
data "aws_ssm_parameter" "bastion_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_security_group" "bastion" {
  count = var.provision_bastion ? 1 : 0

  name        = "${local.name_prefix}-bastion"
  description = "Ephemeral bootstrap bastion. No inbound at all: Session Manager is an outbound connection the agent makes to the SSM endpoints."
  vpc_id      = aws_vpc.platform.id

  tags = merge(local.tags, { Name = "${local.name_prefix}-bastion" })
}

resource "aws_vpc_security_group_egress_rule" "bastion_to_endpoints" {
  count = var.provision_bastion ? 1 : 0

  security_group_id            = aws_security_group.bastion[0].id
  description                  = "HTTPS to the SSM interface endpoints, which is how the agent registers and how a session is carried."
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.bastion_endpoints[0].id
}

resource "aws_vpc_security_group_egress_rule" "bastion_to_rds" {
  count = var.provision_bastion ? 1 : 0

  security_group_id            = aws_security_group.bastion[0].id
  description                  = "Postgres to the shared instance. The only reason this host exists."
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.rds.id
}

# Additive rule on the existing RDS group. It references the bastion group, so
# it disappears with the bastion and leaves the phase 1 rule untouched.
resource "aws_vpc_security_group_ingress_rule" "rds_from_bastion" {
  count = var.provision_bastion ? 1 : 0

  security_group_id            = aws_security_group.rds.id
  description                  = "Postgres from the ephemeral bootstrap bastion."
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.bastion[0].id
}

# A group of its own for the SSM endpoints rather than reusing the phase 1
# endpoint group, so tearing the bastion down removes its whole blast radius
# instead of editing a rule on a group that outlives it.
resource "aws_security_group" "bastion_endpoints" {
  count = var.provision_bastion ? 1 : 0

  name        = "${local.name_prefix}-bastion-vpce"
  description = "Interface endpoints serving Session Manager for the ephemeral bastion. HTTPS from the bastion group only."
  vpc_id      = aws_vpc.platform.id

  tags = merge(local.tags, { Name = "${local.name_prefix}-bastion-vpce" })
}

resource "aws_vpc_security_group_ingress_rule" "bastion_endpoints_from_bastion" {
  count = var.provision_bastion ? 1 : 0

  security_group_id            = aws_security_group.bastion_endpoints[0].id
  description                  = "HTTPS from the bastion group."
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.bastion[0].id
}

# Session Manager needs all three: ssm for the control plane, ssmmessages for
# the session channel, ec2messages for the agent's own polling. Two out of three
# fails in ways that look like a hung session rather than an error.
#
# Only two of them are created here. Phase 2 needs the ssm endpoint permanently,
# for the API Lambda's cold-start parameter reads, and AWS refuses a second
# endpoint for the same service with private DNS in the same VPC. It therefore
# lives in endpoints.tf, and the bastion reaches it through the gated rules
# there. Nothing about the bootstrap procedure changes.
locals {
  bastion_endpoint_services = var.provision_bastion ? toset([
    "com.amazonaws.us-east-1.ssmmessages",
    "com.amazonaws.us-east-1.ec2messages",
  ]) : toset([])
}

resource "aws_vpc_endpoint" "bastion_ssm" {
  for_each = local.bastion_endpoint_services

  vpc_id            = aws_vpc.platform.id
  service_name      = each.value
  vpc_endpoint_type = "Interface"

  subnet_ids         = [aws_subnet.private["a"].id]
  security_group_ids = [aws_security_group.bastion_endpoints[0].id]

  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-${replace(each.value, "com.amazonaws.us-east-1.", "")}" })
}

# AmazonSSMManagedInstanceCore and nothing else. The host needs no AWS API
# access of its own; it is a TCP relay that Session Manager happens to reach.
resource "aws_iam_role" "bastion" {
  count = var.provision_bastion ? 1 : 0

  name = "${local.name_prefix}-bastion"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  count = var.provision_bastion ? 1 : 0

  role       = aws_iam_role.bastion[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  count = var.provision_bastion ? 1 : 0

  name = "${local.name_prefix}-bastion"
  role = aws_iam_role.bastion[0].name

  tags = local.tags
}

resource "aws_instance" "bastion" {
  count = var.provision_bastion ? 1 : 0

  ami           = data.aws_ssm_parameter.bastion_ami.value
  instance_type = var.bastion_instance_type

  subnet_id              = aws_subnet.private["a"].id
  vpc_security_group_ids = [aws_security_group.bastion[0].id]
  iam_instance_profile   = aws_iam_instance_profile.bastion[0].name

  # No public address, and no route to one either. Reachability is Session
  # Manager over the endpoints above, nothing else.
  associate_public_ip_address = false

  # No key pair on purpose: there is no SSH path to this host, so a key would
  # only be a credential to lose.
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-bastion" })
}
