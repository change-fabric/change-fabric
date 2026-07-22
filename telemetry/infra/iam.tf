# ---------------------------------------------------------------------------
# One execution role + one inline, least-privilege policy per Lambda (section 8).
# Each policy is the exact grant list the plan spells out, plus the standard
# CloudWatch Logs trio scoped to that function's own log group. No wildcards on
# resources beyond the log-group name, no delete actions anywhere.
# ---------------------------------------------------------------------------

# Every Lambda assumes its role from the Lambda service; shared trust policy.
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# The standard AWSLambdaBasicExecutionRole-equivalent Logs grant, reused by every
# role below including the authorizer, scoped to the caller's own log group.
locals {
  log_actions = [
    "logs:CreateLogGroup",
    "logs:CreateLogStream",
    "logs:PutLogEvents",
  ]
}

# ---- transcript_ingest (Capability A) ------------------------------------
resource "aws_iam_role" "transcript_ingest" {
  name               = "${local.fn.transcript_ingest}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "transcript_ingest" {
  name = "inline"
  role = aws_iam_role.transcript_ingest.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PutTelemetry"
        Effect   = "Allow"
        Action   = "dynamodb:PutItem"
        Resource = aws_dynamodb_table.telemetry.arn
      },
      {
        Sid      = "PutTranscriptBody"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.transcripts.arn}/*"
      },
      {
        # DynamoDB PutItem against a CMK-encrypted table needs Decrypt too, not
        # only GenerateDataKey/Encrypt: it reads the table's existing data key
        # before writing, discovered when a real PutItem 400'd with
        # AccessDeniedException on kms:Decrypt during the first live smoke test.
        Sid      = "UseCmkForWrite"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Encrypt", "kms:Decrypt"]
        Resource = aws_kms_key.backend.arn
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = local.log_actions
        Resource = local.log_group_arns.transcript_ingest
      },
    ]
  })
}

# ---- transcript_authorizer (Capability A) --------------------------------
# Only needs Logs: its secret arrives as an env var injected at deploy time
# (section 8), so it makes no AWS API call at runtime.
resource "aws_iam_role" "transcript_authorizer" {
  name               = "${local.fn.transcript_authorizer}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "transcript_authorizer" {
  name = "inline"
  role = aws_iam_role.transcript_authorizer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "Logs"
      Effect   = "Allow"
      Action   = local.log_actions
      Resource = local.log_group_arns.transcript_authorizer
    }]
  })
}

# ---- presence (Capability B) ---------------------------------------------
resource "aws_iam_role" "presence" {
  name               = "${local.fn.presence}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "presence" {
  name = "inline"
  role = aws_iam_role.presence.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadTeamKey"
        Effect   = "Allow"
        Action   = "dynamodb:GetItem"
        Resource = aws_dynamodb_table.teams.arn
      },
      {
        Sid      = "ReadWritePresence"
        Effect   = "Allow"
        Action   = ["dynamodb:Query", "dynamodb:PutItem"]
        Resource = aws_dynamodb_table.presence.arn
      },
      {
        Sid      = "UseCmk"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.backend.arn
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = local.log_actions
        Resource = local.log_group_arns.presence
      },
    ]
  })
}

# ---- secret_scanner (Capability C detection) -----------------------------
# The stream actions target the table's STREAM arn; the Query actions target the
# table and its gsi-unscanned index. No delete anywhere (section 8).
resource "aws_iam_role" "secret_scanner" {
  name               = "${local.fn.secret_scanner}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "secret_scanner" {
  name = "inline"
  role = aws_iam_role.secret_scanner.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadTelemetryStream"
        Effect = "Allow"
        Action = [
          "dynamodb:GetRecords",
          "dynamodb:GetShardIterator",
          "dynamodb:DescribeStream",
          "dynamodb:ListStreams",
        ]
        Resource = aws_dynamodb_table.telemetry.stream_arn
      },
      {
        Sid    = "QueryTelemetryAndIndex"
        Effect = "Allow"
        Action = "dynamodb:Query"
        Resource = [
          aws_dynamodb_table.telemetry.arn,
          "${aws_dynamodb_table.telemetry.arn}/index/${local.unscanned_index}",
        ]
      },
      {
        Sid      = "FlipScanStatus"
        Effect   = "Allow"
        Action   = "dynamodb:UpdateItem"
        Resource = aws_dynamodb_table.telemetry.arn
      },
      {
        Sid      = "WriteFinding"
        Effect   = "Allow"
        Action   = "dynamodb:PutItem"
        Resource = aws_dynamodb_table.notifications.arn
      },
      {
        Sid      = "ReadTranscriptBody"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.transcripts.arn}/*"
      },
      {
        Sid      = "SweepCursor"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:PutParameter"]
        Resource = aws_ssm_parameter.sweep_cursor.arn
      },
      {
        Sid      = "UseCmk"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.backend.arn
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = local.log_actions
        Resource = local.log_group_arns.secret_scanner
      },
    ]
  })
}

# ---- notifications (Capability C delivery) -------------------------------
# No S3, no delete (section 8).
resource "aws_iam_role" "notifications" {
  name               = "${local.fn.notifications}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "notifications" {
  name = "inline"
  role = aws_iam_role.notifications.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadTeamKey"
        Effect   = "Allow"
        Action   = "dynamodb:GetItem"
        Resource = aws_dynamodb_table.teams.arn
      },
      {
        Sid      = "ReadWriteFindings"
        Effect   = "Allow"
        Action   = ["dynamodb:Query", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.notifications.arn
      },
      {
        Sid      = "UseCmk"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.backend.arn
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = local.log_actions
        Resource = local.log_group_arns.notifications
      },
    ]
  })
}
