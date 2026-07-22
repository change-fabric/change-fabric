# ---------------------------------------------------------------------------
# Five Ruby Lambdas (section 6, section 8). Three ship as plain zips built from
# their local directory; two (presence, notifications) ship as ECR container
# images because they link the native ed25519 gem (see ecr.tf and variables.tf).
# ---------------------------------------------------------------------------

# Zip the three plain-zip build directories at plan time. output_base64sha256
# drives source_code_hash so a rebuilt directory redeploys. These directories are
# populated by the Lambda build step (handler.rb + vendored gems); a Terraform-
# only pass just packages whatever is present.
data "archive_file" "transcript_ingest" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/transcript_ingest"
  output_path = "${path.module}/build/transcript_ingest.zip"
}

data "archive_file" "transcript_authorizer" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/transcript_authorizer"
  output_path = "${path.module}/build/transcript_authorizer.zip"
}

data "archive_file" "secret_scanner" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/secret_scanner"
  output_path = "${path.module}/build/secret_scanner.zip"
}

# ---- transcript_ingest (Capability A, plain zip) -------------------------
# Sized for the large case: a multi-MB base64 body decoded in memory before the
# S3 offload, so it gets more memory and a generous timeout even though it is
# fire-and-forget.
resource "aws_lambda_function" "transcript_ingest" {
  function_name    = local.fn.transcript_ingest
  role             = aws_iam_role.transcript_ingest.arn
  runtime          = "ruby3.4"
  handler          = local.ruby_handler
  filename         = data.archive_file.transcript_ingest.output_path
  source_code_hash = data.archive_file.transcript_ingest.output_base64sha256
  memory_size      = 512
  timeout          = 30

  environment {
    variables = {
      TABLE_NAME  = aws_dynamodb_table.telemetry.name
      BUCKET_NAME = aws_s3_bucket.transcripts.bucket
      INLINE_MAX  = "350000"
    }
  }
}

# ---- transcript_authorizer (Capability A, plain zip) ---------------------
# The shared secret is injected here at deploy time from SSM (data source in
# main.tf); the Lambda only reads its env var. Marked nowhere else.
resource "aws_lambda_function" "transcript_authorizer" {
  function_name    = local.fn.transcript_authorizer
  role             = aws_iam_role.transcript_authorizer.arn
  runtime          = "ruby3.4"
  handler          = local.ruby_handler
  filename         = data.archive_file.transcript_authorizer.output_path
  source_code_hash = data.archive_file.transcript_authorizer.output_base64sha256
  memory_size      = 128
  timeout          = 5

  environment {
    variables = sensitive({
      TELEMETRY_SECRET = data.aws_ssm_parameter.api_secret.value
    })
  }
}

# ---- presence (Capability B, container image) ----------------------------
# package_type = "Image": ruby3.4 comes from the container base image, so runtime
# and handler are set inside the image, not here. image_uri is a deployer-supplied
# variable (built and pushed to the ECR repo first; see README).
resource "aws_lambda_function" "presence" {
  function_name = local.fn.presence
  role          = aws_iam_role.presence.arn
  package_type  = "Image"
  image_uri     = var.presence_image_uri
  memory_size   = 256
  timeout       = 5

  environment {
    variables = {
      PRESENCE_TABLE  = aws_dynamodb_table.presence.name
      TEAMS_TABLE     = aws_dynamodb_table.teams.name
      PRESENCE_TTL    = "900"
      TS_SKEW_SECONDS = "300"
    }
  }
}

# ---- secret_scanner (Capability C detection, plain zip) ------------------
# Invoked only by the DynamoDB stream mapping and the hourly EventBridge rule
# (events.tf), never over HTTP. Timeout leaves room for the sweep to page a
# backlog within one run.
resource "aws_lambda_function" "secret_scanner" {
  function_name    = local.fn.secret_scanner
  role             = aws_iam_role.secret_scanner.arn
  runtime          = "ruby3.4"
  handler          = local.ruby_handler
  filename         = data.archive_file.secret_scanner.output_path
  source_code_hash = data.archive_file.secret_scanner.output_base64sha256
  memory_size      = 512
  timeout          = 120

  environment {
    variables = {
      TABLE_NAME          = aws_dynamodb_table.telemetry.name
      UNSCANNED_INDEX     = local.unscanned_index
      BUCKET_NAME         = aws_s3_bucket.transcripts.bucket
      NOTIFICATIONS_TABLE = aws_dynamodb_table.notifications.name
      SWEEP_CURSOR_PARAM  = aws_ssm_parameter.sweep_cursor.name
      SWEEP_PAGE_LIMIT    = "100"
    }
  }
}

# ---- notifications (Capability C delivery, container image) --------------
# Serves POST /notifications and POST /notifications/ack, dispatched by path
# inside the handler. Container image for the same ed25519 reason as presence.
resource "aws_lambda_function" "notifications" {
  function_name = local.fn.notifications
  role          = aws_iam_role.notifications.arn
  package_type  = "Image"
  image_uri     = var.notifications_image_uri
  memory_size   = 256
  timeout       = 10

  environment {
    variables = {
      NOTIFICATIONS_TABLE = aws_dynamodb_table.notifications.name
      TEAMS_TABLE         = aws_dynamodb_table.teams.name
      TS_SKEW_SECONDS     = "300"
    }
  }
}
