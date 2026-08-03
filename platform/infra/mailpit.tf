# ---------------------------------------------------------------------------
# Mailpit: the staging mailbox a human can actually open.
#
# SES is in the sandbox on this account, so a verification or invitation mail to
# any address that is not pre-verified is rejected. `email.ts` swallows that
# rejection on purpose (a sign-up must not fail because of an unrelated AWS
# support ticket), which leaves staging with mail that provably left the API and
# provably went nowhere readable. Mailpit closes that loop: it accepts SMTP on
# 1025, stores nothing anywhere else, and renders the message at
# https://mailpit.staging.changefabric.org behind the same staging Basic Auth
# gate as every other surface.
#
# Nothing about the VPC changes. There is still no internet gateway and no NAT.
# The three facts that make that hold:
#
#   1. The image is pulled from a PRIVATE ECR repository in this account,
#      through interface endpoints (`ecr.api`, `ecr.dkr`) and the existing S3
#      gateway endpoint, which is where ECR keeps layer blobs. See endpoints.tf.
#   2. Nothing about getting the image INTO that repository happens inside the
#      VPC. `platform/mailpit/mirror-image.sh` runs on a laptop or in CI and
#      pushes; the VPC only ever pulls. See README.md for why this is a mirror
#      rather than an ECR pull-through cache.
#   3. The public surface is CloudFront in front of an API Gateway HTTP API,
#      which reaches an INTERNAL load balancer over a VPC LINK. The link's
#      network interfaces live in the same private subnets and need no route
#      out; the public leg is API Gateway's own regional endpoint, which is not
#      in this VPC at all. No subnet gains a route, no resource gains a public
#      IP.
#
#      A CloudFront VPC origin was the first design and AWS refused it: the
#      CreateVpcOrigin API requires an internet gateway attached to the VPC even
#      though it never routes origin traffic through one. See the block above
#      the API Gateway resources below, and README.md.
# ---------------------------------------------------------------------------

locals {
  mailpit_domain  = "mailpit.staging.${var.domain}"
  mailpit_auth_fn = "${local.name_prefix}-mailpit-staging-basic-auth"

  # The API Gateway host CloudFront uses as its origin. Not a host anybody
  # visits: it is the far end of the public leg, and it answers 401 to anyone
  # who finds it because Mailpit applies the same credential itself.
  mailpit_origin_domain = "mailpit-origin.staging.${var.domain}"

  # Mailpit's two listeners. 1025 is SMTP submission from the API Lambda, 8025
  # is the web UI and its JSON API. Both are the image's own defaults.
  mailpit_smtp_port = 1025
  mailpit_http_port = 8025

  # Where the Lambda dials SMTP. A Cloud Map A record over the task's own ENI
  # address, so the Lambda needs neither a load balancer on the SMTP side nor a
  # task IP written into an environment variable that goes stale on the next
  # deployment.
  mailpit_namespace = "cf-platform.internal"
  mailpit_smtp_host = "mailpit.${local.mailpit_namespace}"
}

# ---------------------------------------------------------------------------
# The image, in a private repository in this account.
#
# IMMUTABLE tags, deliberately: the task definition names a tag, and an
# immutable tag makes that name a pin rather than a hint. Re-mirroring the same
# tag is then a loud error instead of a silent swap of what staging runs.
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "mailpit" {
  name                 = "cf-platform/mailpit"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  # AES256 rather than the platform CMK. The contents are a public upstream
  # image, so a customer-managed key would add a key policy to maintain and a
  # kms:Decrypt grant on the execution role for no confidentiality this image
  # does not already lack by being public.
  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-mailpit" })
}

# Old mirrored versions are not worth storage after a few upgrades, and nothing
# rolls back to one: a rollback is a re-mirror of the tag it wants.
resource "aws_ecr_lifecycle_policy" "mailpit" {
  repository = aws_ecr_repository.mailpit.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the five most recent mirrored versions."
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------------------
# Security groups.
#
# Three, and the direction of every rule is the design: the ALB may reach the
# task, the task may reach nothing but AWS endpoints, and the only thing that
# may reach SMTP is the API Lambda.
# ---------------------------------------------------------------------------

resource "aws_security_group" "mailpit" {
  name        = "${local.name_prefix}-mailpit"
  description = "Mailpit Fargate task. SMTP from the Lambda group, HTTP from the internal load balancer, and nothing else."
  vpc_id      = aws_vpc.platform.id

  tags = merge(local.tags, { Name = "${local.name_prefix}-mailpit" })
}

# The point of the whole change: the API Lambda can hand a message to Mailpit.
resource "aws_vpc_security_group_ingress_rule" "mailpit_smtp_from_lambda" {
  security_group_id            = aws_security_group.mailpit.id
  description                  = "SMTP submission from the platform Lambda group."
  from_port                    = local.mailpit_smtp_port
  to_port                      = local.mailpit_smtp_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.lambda.id
}

resource "aws_vpc_security_group_ingress_rule" "mailpit_http_from_alb" {
  security_group_id            = aws_security_group.mailpit.id
  description                  = "Web UI and JSON API from the internal load balancer only."
  from_port                    = local.mailpit_http_port
  to_port                      = local.mailpit_http_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.mailpit_alb.id
}

# Egress is wide for the same reason the Lambda group's is: there is no internet
# route, so the reachable set is the VPC and its endpoints regardless of what
# this rule says. It has to exist at all because the task pulls its own image
# from ECR and ships its own logs, both over 443 to interface endpoints.
resource "aws_vpc_security_group_egress_rule" "mailpit_all" {
  security_group_id = aws_security_group.mailpit.id
  description       = "All egress. Constrained in practice by the absence of any internet route."
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "mailpit_alb" {
  name        = "${local.name_prefix}-mailpit-alb"
  description = "Internal load balancer in front of Mailpit. Ingress from the API Gateway VPC link only."
  vpc_id      = aws_vpc.platform.id

  tags = merge(local.tags, { Name = "${local.name_prefix}-mailpit-alb" })
}

# The only thing that may open this listener is the VPC link, which is the only
# thing that can: the load balancer is internal and has no public address, so a
# request reaching it has already come through API Gateway and, before that,
# through the distribution and its Basic Auth function.
resource "aws_vpc_security_group_ingress_rule" "mailpit_alb_from_link" {
  security_group_id            = aws_security_group.mailpit_alb.id
  description                  = "HTTP from the API Gateway VPC link interfaces."
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.mailpit_link.id
}

resource "aws_vpc_security_group_egress_rule" "mailpit_alb_to_task" {
  security_group_id            = aws_security_group.mailpit_alb.id
  description                  = "Forward to the Mailpit task web listener."
  from_port                    = local.mailpit_http_port
  to_port                      = local.mailpit_http_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.mailpit.id
}

# ---------------------------------------------------------------------------
# The internal load balancer.
#
# It exists because a CloudFront VPC origin targets a load balancer or an EC2
# instance, never a bare ECS service. It is also what gives the service a stable
# address on the HTTP side while task ENIs come and go.
#
# `internal = true` is not a default worth leaving implicit: an internet-facing
# load balancer requires public subnets with a route to an internet gateway, and
# there are none in this VPC and never will be.
# ---------------------------------------------------------------------------

resource "aws_lb" "mailpit" {
  name               = "${local.name_prefix}-mailpit"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.mailpit_alb.id]

  # Both AZs because an application load balancer requires at least two, even
  # when a single task sits behind it.
  subnets = [aws_subnet.private["a"].id, aws_subnet.private["b"].id]

  tags = merge(local.tags, { Name = "${local.name_prefix}-mailpit" })
}

resource "aws_lb_target_group" "mailpit" {
  name        = "${local.name_prefix}-mailpit"
  port        = local.mailpit_http_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.platform.id
  target_type = "ip"

  # Mailpit answers /livez as soon as the HTTP listener is up, which is what the
  # target group is asking about. /readyz additionally reports storage state and
  # would make a healthy instance look unhealthy while it compacts.
  health_check {
    path                = "/livez"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # A message list is per-viewer state in practice; there is nothing to pin a
  # viewer to, because there is one task.
  deregistration_delay = 10

  tags = merge(local.tags, { Name = "${local.name_prefix}-mailpit" })
}

# HTTP, not HTTPS. The listener is unreachable from outside the VPC (the load
# balancer is internal), and the leg CloudFront runs to it stays on AWS's own
# network. Terminating TLS here as well would need a second certificate for a
# private name nothing validates against.
resource "aws_lb_listener" "mailpit" {
  load_balancer_arn = aws_lb.mailpit.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mailpit.arn
  }
}

# ---------------------------------------------------------------------------
# The Fargate service.
#
# Fargate rather than EC2 because this estate runs nothing on a bare instance
# except the ephemeral SSM bastion, and a mail catcher is not a good reason to
# start. ARM64 to match every other compute here, and because the upstream image
# is a real multi-arch manifest rather than an amd64 build with a note.
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "platform" {
  name = local.name_prefix

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = merge(local.tags, { Name = local.name_prefix })
}

resource "aws_cloudwatch_log_group" "mailpit" {
  name              = "/aws/ecs/${local.name_prefix}-mailpit"
  retention_in_days = 30

  tags = local.tags
}

# The EXECUTION role, which is what pulls the image and writes the log stream.
# The task itself gets no role at all: Mailpit calls no AWS API, so giving it an
# identity would only be an identity to misuse.
resource "aws_iam_role" "mailpit_execution" {
  name = "${local.name_prefix}-mailpit-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "mailpit_execution" {
  role       = aws_iam_role.mailpit_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Reading the ONE staging credential, so the container can apply it itself. The
# execution role does this before the container starts, which is why it is here
# rather than on a task role: Mailpit never calls AWS, it just receives the value
# as an environment variable it was started with.
resource "aws_iam_role_policy" "mailpit_execution" {
  name = "${local.name_prefix}-mailpit-execution"
  role = aws_iam_role.mailpit_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadStagingBasicAuthCredential"
        Effect   = "Allow"
        Action   = ["ssm:GetParameters"]
        Resource = ["arn:aws:ssm:us-east-1:${data.aws_caller_identity.current.account_id}:parameter${local.staging_basic_auth_param}"]
      },
      {
        Sid      = "DecryptParameters"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [data.aws_kms_key.ssm.arn]
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.us-east-1.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_ecs_task_definition" "mailpit" {
  family                   = "${local.name_prefix}-mailpit"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.mailpit_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name  = "mailpit"
    image = "${aws_ecr_repository.mailpit.repository_url}:${var.mailpit_image_tag}"

    essential = true

    portMappings = [
      { containerPort = local.mailpit_smtp_port, protocol = "tcp" },
      { containerPort = local.mailpit_http_port, protocol = "tcp" },
    ]

    environment = [
      # Storage is in-memory by default and stays that way: a Fargate task has
      # no durable disk worth attaching for a mailbox whose whole purpose is to
      # be read within minutes of a test. A cap keeps a runaway loop from
      # exhausting the task's memory.
      { name = "MP_MAX_MESSAGES", value = "500" },
      # No SMTP authentication. The only thing that can open 1025 is the API
      # Lambda's security group, which is a stronger statement than a password
      # would be, and it saves putting a second credential in SSM.
      { name = "MP_SMTP_AUTH_ACCEPT_ANY", value = "true" },
      { name = "MP_SMTP_AUTH_ALLOW_INSECURE", value = "true" },
    ]

    # Mailpit applies the SAME staging credential to its own web listener, read
    # from the SAME SSM parameter every other surface reads. There is no second
    # credential anywhere in this change.
    #
    # This is the second gate, not the first: the CloudFront Function in front of
    # the distribution is what a browser meets. This one covers the case the
    # function cannot, which is somebody who finds the API Gateway origin host
    # directly. The value is a `user:pass` pair, which is exactly the format
    # MP_UI_AUTH wants, so nothing has to reshape it.
    #
    # /livez and /readyz stay exempt inside Mailpit, so the load balancer's
    # health check is unaffected. That was measured against the image this task
    # runs, not assumed.
    secrets = [
      {
        name      = "MP_UI_AUTH"
        valueFrom = "arn:aws:ssm:us-east-1:${data.aws_caller_identity.current.account_id}:parameter${local.staging_basic_auth_param}"
      },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.mailpit.name
        "awslogs-region"        = "us-east-1"
        "awslogs-stream-prefix" = "mailpit"
      }
    }
  }])

  tags = merge(local.tags, { Name = "${local.name_prefix}-mailpit" })
}

# ---------------------------------------------------------------------------
# Service discovery, so the Lambda has a name to dial for SMTP.
#
# The web side has a load balancer; the SMTP side deliberately does not. An
# application load balancer speaks HTTP and cannot carry SMTP, and a network
# load balancer for one long-lived task would be a second balancer to pay for
# and to health-check. Cloud Map registers the task's own ENI address as an A
# record in a private zone this VPC already resolves, which is exactly as much
# indirection as one task needs.
# ---------------------------------------------------------------------------

resource "aws_service_discovery_private_dns_namespace" "platform" {
  name        = local.mailpit_namespace
  description = "Private names for platform services reachable only inside the VPC."
  vpc         = aws_vpc.platform.id

  tags = local.tags
}

resource "aws_service_discovery_service" "mailpit" {
  name = "mailpit"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.platform.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  # ECS owns the health of its own task, so Cloud Map is told to take ECS's word
  # for it rather than running a second check it has no path to perform.
  health_check_custom_config {
    failure_threshold = 1
  }

  tags = local.tags
}

resource "aws_ecs_service" "mailpit" {
  name            = "${local.name_prefix}-mailpit"
  cluster         = aws_ecs_cluster.platform.id
  task_definition = aws_ecs_task_definition.mailpit.arn
  launch_type     = "FARGATE"

  # One. Mailpit stores messages in the task's own memory, so a second replica
  # would be a second mailbox and a coin flip over which one holds the mail
  # somebody is looking for.
  desired_count = 1

  network_configuration {
    subnets          = [aws_subnet.private["a"].id, aws_subnet.private["b"].id]
    security_groups  = [aws_security_group.mailpit.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.mailpit.arn
    container_name   = "mailpit"
    container_port   = local.mailpit_http_port
  }

  service_registries {
    registry_arn = aws_service_discovery_service.mailpit.arn
  }

  # The image pull needs the endpoints to exist first. Terraform infers no edge
  # from a task definition to a VPC endpoint, so it is stated.
  depends_on = [
    aws_lb_listener.mailpit,
    aws_vpc_endpoint.platform,
    aws_vpc_endpoint.s3,
  ]

  tags = merge(local.tags, { Name = "${local.name_prefix}-mailpit" })
}

# ---------------------------------------------------------------------------
# The public surface, and why it is not a CloudFront VPC origin.
#
# A CloudFront VPC origin is the obvious answer to "CloudFront in front of a
# fully private backend", and it was the design until AWS refused it:
#
#   $ aws cloudfront create-vpc-origin --vpc-origin-endpoint-config ...
#   An error occurred (InvalidArgument) when calling the CreateVpcOrigin
#   operation: does not have an internet gateway in its VPC
#
# That is not a routing requirement, and the documentation is explicit that the
# gateway is never used to carry origin traffic: "The internet gateway is
# required to denote that the VPC can receive traffic from the internet ... you
# don't need to update the routing policies." It is nonetheless a hard
# precondition, checked at the API, and satisfying it means attaching an
# internet gateway to this VPC. This estate's standing rule is that adding one
# is a decision for a human rather than a side effect of a feature, so it was
# not added. See README.md.
#
# API Gateway's HTTP API with a VPC LINK is the substitute, and it needs no
# internet gateway at all: the link puts elastic network interfaces in the same
# private subnets and reaches the internal load balancer across them. The public
# leg is API Gateway's own regional endpoint, which is AWS-managed and outside
# the VPC entirely. CloudFront sits in front of that, which is exactly the shape
# webapp.tf already uses for /api/* and /v1/*, so the Basic Auth function, the
# certificate and the alias record are all unchanged from the original design.
# ---------------------------------------------------------------------------

resource "aws_security_group" "mailpit_link" {
  name        = "${local.name_prefix}-mailpit-link"
  description = "API Gateway VPC link interfaces. Egress to the internal load balancer only."
  vpc_id      = aws_vpc.platform.id

  tags = merge(local.tags, { Name = "${local.name_prefix}-mailpit-link" })
}

resource "aws_vpc_security_group_egress_rule" "mailpit_link_to_alb" {
  security_group_id            = aws_security_group.mailpit_link.id
  description                  = "HTTP to the internal load balancer in front of Mailpit."
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.mailpit_alb.id
}

resource "aws_apigatewayv2_vpc_link" "mailpit" {
  name               = "${local.name_prefix}-mailpit"
  subnet_ids         = [aws_subnet.private["a"].id, aws_subnet.private["b"].id]
  security_group_ids = [aws_security_group.mailpit_link.id]

  tags = merge(local.tags, { Name = "${local.name_prefix}-mailpit" })
}

resource "aws_apigatewayv2_api" "mailpit" {
  name          = "${local.name_prefix}-mailpit"
  description   = "Public edge for the staging Mailpit UI, over a VPC link to a private load balancer."
  protocol_type = "HTTP"

  # The generated https://<id>.execute-api.us-east-1.amazonaws.com endpoint is
  # turned OFF. Left on it would be a second, unadvertised way to reach the
  # mailbox that no CloudFront Function sits in front of, and "nobody will guess
  # the id" is not an access control. The only way in is the custom domain
  # below, and the only thing that uses that is the distribution.
  disable_execute_api_endpoint = true

  tags = local.tags
}

resource "aws_apigatewayv2_integration" "mailpit" {
  api_id = aws_apigatewayv2_api.mailpit.id

  integration_type   = "HTTP_PROXY"
  integration_uri    = aws_lb_listener.mailpit.arn
  integration_method = "ANY"
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.mailpit.id

  payload_format_version = "1.0"
}

resource "aws_apigatewayv2_route" "mailpit" {
  api_id    = aws_apigatewayv2_api.mailpit.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.mailpit.id}"
}

resource "aws_apigatewayv2_stage" "mailpit" {
  api_id      = aws_apigatewayv2_api.mailpit.id
  name        = "$default"
  auto_deploy = true

  tags = local.tags
}

# A second host, and it is deliberately not the one anybody types. It exists
# because API Gateway needs somewhere to answer once its generated endpoint is
# off, and because CloudFront needs an origin hostname. It is covered by the
# same wildcard certificate, so dns.tf is untouched.
resource "aws_apigatewayv2_domain_name" "mailpit" {
  domain_name = local.mailpit_origin_domain

  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.staging.certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  tags = merge(local.tags, { Name = local.mailpit_origin_domain })
}

resource "aws_apigatewayv2_api_mapping" "mailpit" {
  api_id      = aws_apigatewayv2_api.mailpit.id
  domain_name = aws_apigatewayv2_domain_name.mailpit.id
  stage       = aws_apigatewayv2_stage.mailpit.id
}

resource "aws_route53_record" "mailpit_origin" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = local.mailpit_origin_domain
  type    = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.mailpit.domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.mailpit.domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}

# Same arrangement as the web app and the artifacts host: the digest is compiled
# in by a deploy script and read back here, so it reaches neither the state file
# nor a plan. platform/mailpit/deploy.sh is the only thing that ever holds it.
data "aws_cloudfront_function" "mailpit_basic_auth" {
  name  = local.mailpit_auth_fn
  stage = "LIVE"
}

resource "aws_cloudfront_distribution" "mailpit" {
  enabled         = true
  is_ipv6_enabled = true
  aliases         = [local.mailpit_domain]
  comment         = "change-fabric staging mailpit"
  price_class     = "PriceClass_100"

  origin {
    domain_name = aws_apigatewayv2_domain_name.mailpit.domain_name
    origin_id   = "mailpit-api-gateway"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Nothing here is cacheable. A mail catcher is a live view of a mailbox, and
  # its JSON API answers a different list on every poll; caching would show a
  # tester the mailbox as it was rather than as it is.
  default_cache_behavior {
    target_origin_id       = "mailpit-api-gateway"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.disabled.id

    # Everything except Host. Mailpit's UI holds a websocket open for live
    # updates, and the upgrade handshake is a set of request headers; dropping
    # them leaves the list frozen until a manual reload.
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    compress                 = true

    function_association {
      event_type   = "viewer-request"
      function_arn = data.aws_cloudfront_function.mailpit_basic_auth.arn
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    # The existing wildcard already covers mailpit.staging, so this host needs
    # no change to the certificate in dns.tf.
    acm_certificate_arn      = aws_acm_certificate_validation.staging.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = merge(local.tags, { Name = local.mailpit_domain })
}

resource "aws_route53_record" "mailpit" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = local.mailpit_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.mailpit.domain_name
    zone_id                = aws_cloudfront_distribution.mailpit.hosted_zone_id
    evaluate_target_health = false
  }
}
