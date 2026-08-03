# ---------------------------------------------------------------------------
# The staging API, and the maintenance function that reaches the database for
# it.
#
# Both run the same bundle from platform/api, built by `npm run build` there
# before an apply. They differ in handler, size, timeout, and whether anything
# routes to them: cf-platform-api answers API Gateway, cf-platform-migrate is
# only ever invoked directly.
#
# The maintenance function exists because the database has no path from outside
# the VPC. Phase 1 solved that once with an ephemeral bastion; migrations and
# row checks recur, so they get a function instead of an instance.
# ---------------------------------------------------------------------------

data "archive_file" "api_bundle" {
  type        = "zip"
  source_dir  = "${path.module}/../api/dist"
  output_path = "${path.module}/build/platform-api.zip"
}

locals {
  api_domain    = "api.staging.${var.domain}"
  cookie_domain = ".staging.${var.domain}"
  app_origin    = "https://app.staging.${var.domain}"

  ses_from_address = var.ses_from_address != "" ? var.ses_from_address : "no-reply@staging.${var.domain}"

  # Exactly the parameters the two functions read, named individually rather
  # than as a /cf-platform/* wildcard so the policy says what it means.
  read_parameter_arns = [
    for name in [
      local.db_master_password_param,
      local.staging_db_password_param,
      local.staging_auth_secret_param,
      local.staging_basic_auth_param,
      local.staging_signer_key_param,
    ] : "arn:aws:ssm:us-east-1:${data.aws_caller_identity.current.account_id}:parameter${name}"
  ]

  database_environment = {
    DB_HOST = aws_db_instance.platform.address
    DB_PORT = tostring(aws_db_instance.platform.port)
    DB_NAME = local.staging_database
    DB_USER = local.staging_role
  }
}

# SecureString values here are encrypted under the account's AWS managed SSM
# key, so GetParameter with decryption needs kms:Decrypt on that key as well as
# the SSM permission itself.
data "aws_kms_key" "ssm" {
  key_id = "alias/aws/ssm"
}

resource "aws_iam_role" "api" {
  name = "${local.name_prefix}-api"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

# Creating and deleting the ENIs a VPC-attached function needs. This is the one
# AWS managed policy in the config: the actions are EC2-wide by nature, and a
# hand-written copy would only be the same statements with a local name.
resource "aws_iam_role_policy_attachment" "api_vpc_access" {
  role       = aws_iam_role.api.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "api" {
  name = "${local.name_prefix}-api"
  role = aws_iam_role.api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadOwnParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = local.read_parameter_arns
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
      {
        Sid    = "SendTransactionalMail"
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail",
        ]
        Resource = ["arn:aws:ses:us-east-1:${data.aws_caller_identity.current.account_id}:identity/*"]
      },
      # Presigning is signing, and a presigned URL carries THIS role's authority
      # rather than the authority of whoever follows it. The browser or CI job
      # that uploads or downloads is anonymous to S3; the request is evaluated
      # against these two statements. That is why they are here at all, and why
      # they are scoped to one bucket by ARN rather than to s3:* anywhere.
      #
      # ListBucket is deliberately absent. Nothing in the API enumerates the
      # bucket: every key it touches comes from an `artifact_file` row, so the
      # database is the index and a listing would only be a second, weaker one.
      {
        Sid    = "ReadWriteArtifactObjects"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
        ]
        Resource = ["${aws_s3_bucket.artifacts.arn}/*"]
      },
      # The bucket's default encryption is SSE-KMS under the platform CMK, so a
      # PUT needs a data key and a GET needs it decrypted. Both happen on behalf
      # of this role because this role signed the request, which is exactly why
      # the condition pins them to arriving through S3: this grant is for
      # storing artifacts and for nothing else.
      {
        Sid      = "EncryptArtifactObjects"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = [aws_kms_key.platform.arn]
        Condition = {
          StringEquals = { "kms:ViaService" = "s3.us-east-1.amazonaws.com" }
        }
      },
      {
        Sid    = "WriteOwnLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          "${aws_cloudwatch_log_group.api.arn}:*",
          "${aws_cloudwatch_log_group.migrate.arn}:*",
          "${aws_cloudwatch_log_group.api_access.arn}:*",
        ]
      },
    ]
  })
}

# Declared rather than left to the Lambda service to create implicitly, so the
# retention is set from the start instead of defaulting to never expiring.
resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${local.name_prefix}-api"
  retention_in_days = 30

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "migrate" {
  name              = "/aws/lambda/${local.name_prefix}-migrate"
  retention_in_days = 30

  tags = local.tags
}

resource "aws_lambda_function" "api" {
  function_name = "${local.name_prefix}-api"
  role          = aws_iam_role.api.arn

  filename         = data.archive_file.api_bundle.output_path
  source_code_hash = data.archive_file.api_bundle.output_base64sha256

  runtime       = "nodejs22.x"
  architectures = ["arm64"]
  handler       = "index.handler"

  memory_size = 512
  timeout     = 15

  # A ceiling, not a target. It bounds how many Postgres connections this
  # function can hold open against a db.t4g.small that also has to serve every
  # later phase.
  reserved_concurrent_executions = 10

  vpc_config {
    subnet_ids         = [aws_subnet.private["a"].id, aws_subnet.private["b"].id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = merge(local.database_environment, {
      BASIC_AUTH_PARAMETER         = local.staging_basic_auth_param
      BETTER_AUTH_SECRET_PARAMETER = local.staging_auth_secret_param
      DB_PASSWORD_PARAMETER        = local.staging_db_password_param

      API_BASE_URL     = "https://${local.api_domain}"
      COOKIE_DOMAIN    = local.cookie_domain
      TRUSTED_ORIGINS  = join(",", ["https://${local.api_domain}", local.app_origin])
      SES_FROM_ADDRESS = local.ses_from_address

      # Where an invitation mail links to. Named separately from
      # TRUSTED_ORIGINS rather than parsed out of it, because that list is a set
      # of origins allowed to call and this is one specific place to send a
      # person; reading a link target out of a position in a list would break the
      # day a third origin is trusted.
      APP_ORIGIN = local.app_origin

      # The artifacts host. Four values that are set together or not at all, so
      # a half-configured host is a loud failure at cold start rather than a
      # 500 on the first publish. The signer parameter is a NAME, not a value:
      # the private key is read from SSM at cold start and never appears here,
      # in state, or in a plan.
      ARTIFACTS_BUCKET           = aws_s3_bucket.artifacts.bucket
      ARTIFACTS_ORIGIN           = "https://${local.artifacts_domain}"
      ARTIFACTS_KEY_PAIR_ID      = aws_cloudfront_public_key.artifacts_signer.id
      ARTIFACTS_SIGNER_PARAMETER = local.staging_signer_key_param
    })
  }

  depends_on = [
    aws_cloudwatch_log_group.api,
    aws_iam_role_policy_attachment.api_vpc_access,
  ]

  tags = merge(local.tags, { Name = "${local.name_prefix}-api" })
}

resource "aws_lambda_function" "migrate" {
  function_name = "${local.name_prefix}-migrate"
  role          = aws_iam_role.api.arn

  filename         = data.archive_file.api_bundle.output_path
  source_code_hash = data.archive_file.api_bundle.output_base64sha256

  runtime       = "nodejs22.x"
  architectures = ["arm64"]
  handler       = "migrate.handler"

  # A migration is one long single-threaded run rather than a request, so it
  # gets room and time an API request never needs.
  memory_size = 1024
  timeout     = 300

  vpc_config {
    subnet_ids         = [aws_subnet.private["a"].id, aws_subnet.private["b"].id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = merge(local.database_environment, {
      DB_PASSWORD_PARAMETER        = local.staging_db_password_param
      DB_MASTER_USER               = aws_db_instance.platform.username
      DB_MASTER_PASSWORD_PARAMETER = local.db_master_password_param
    })
  }

  depends_on = [
    aws_cloudwatch_log_group.migrate,
    aws_iam_role_policy_attachment.api_vpc_access,
  ]

  tags = merge(local.tags, { Name = "${local.name_prefix}-migrate" })
}
