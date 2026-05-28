# Scheduled "reaper" that destroys EXPIRED artifacts from the static-site bucket.
#
# TTL self-destruct is a DEFAULT behavior of this platform: enable_reaper is true
# by default. On a schedule (reaper_schedule, default daily) a Lambda lists the
# `p/` prefix, reads each artifact's `expires-at` S3 object tag, and for any whose
# timestamp is in the past it DELETES the entire `p/<id>/` prefix from S3 (the
# source of truth) and invalidates CloudFront for `/p/<id>/*`. A tag of `never`
# (or a missing tag) is kept forever.
#
# Everything here is gated on var.enable_reaper via `count`. All reaper-specific
# variables and outputs live in this file intentionally; the rest of the module's
# variables/outputs are defined in variables.tf / outputs.tf.

variable "enable_reaper" {
  description = "Toggle for the scheduled TTL reaper that destroys expired artifacts. On by default -- TTL self-destruct is a default platform behavior. Set false to keep all artifacts forever."
  type        = bool
  default     = true
}

variable "reaper_schedule" {
  description = "EventBridge schedule expression controlling how often the reaper runs, e.g. \"rate(1 day)\" or \"cron(0 7 * * ? *)\"."
  type        = string
  default     = "rate(1 day)"
}

locals {
  reaper_count = var.enable_reaper ? 1 : 0
  # Lambda function names cannot contain dots; the domain (e.g.
  # artifacts.pstaylor.net) does. Sanitize to a DNS-safe-ish slug for resource
  # names that disallow ".".
  reaper_slug = "${replace(var.domain, ".", "-")}-reaper"
}

# Package ONLY lambda/reaper.mjs into its own zip (distinct from the analytics
# archive output path) so views.mjs is never bundled into the reaper function.
data "archive_file" "reaper" {
  count = local.reaper_count

  type        = "zip"
  source_file = "${path.module}/lambda/reaper.mjs"
  output_path = "${path.module}/.terraform-build/reaper.zip"
}

# IAM assume-role policy for the Lambda service principal.
data "aws_iam_policy_document" "reaper_assume_role" {
  count = local.reaper_count

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "reaper" {
  count = local.reaper_count

  name               = "${local.reaper_slug}-lambda"
  assume_role_policy = data.aws_iam_policy_document.reaper_assume_role[0].json
  tags               = var.tags
}

# CloudWatch Logs via the AWS-managed basic execution policy.
resource "aws_iam_role_policy_attachment" "reaper_basic_execution" {
  count = local.reaper_count

  role       = aws_iam_role.reaper[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Least-privilege inline policy: list the bucket, read object tags + delete
# objects under it, and create CloudFront invalidations on this distribution.
# The bucket is referenced by name (bucket name == var.domain) to avoid coupling
# to the bucket resource address.
data "aws_iam_policy_document" "reaper" {
  count = local.reaper_count

  statement {
    sid       = "ListArtifactsBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.domain}"]
  }

  statement {
    sid    = "ReadTagsAndDeleteObjects"
    effect = "Allow"
    actions = [
      "s3:GetObjectTagging",
      "s3:DeleteObject",
    ]
    resources = ["arn:aws:s3:::${var.domain}/*"]
  }

  statement {
    sid       = "InvalidateCloudFront"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = [aws_cloudfront_distribution.artifacts.arn]
  }
}

resource "aws_iam_role_policy" "reaper" {
  count = local.reaper_count

  name   = "${local.reaper_slug}"
  role   = aws_iam_role.reaper[0].id
  policy = data.aws_iam_policy_document.reaper[0].json
}

# Log group, created explicitly so retention is bounded.
resource "aws_cloudwatch_log_group" "reaper" {
  count = local.reaper_count

  name              = "/aws/lambda/${local.reaper_slug}"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_lambda_function" "reaper" {
  count = local.reaper_count

  function_name    = "${local.reaper_slug}"
  role             = aws_iam_role.reaper[0].arn
  runtime          = "nodejs20.x"
  handler          = "reaper.handler"
  filename         = data.archive_file.reaper[0].output_path
  source_code_hash = data.archive_file.reaper[0].output_base64sha256
  timeout          = 120
  memory_size      = 256

  environment {
    variables = {
      BUCKET          = var.domain
      DISTRIBUTION_ID = aws_cloudfront_distribution.artifacts.id
      PREFIX          = "p/"
    }
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy.reaper,
    aws_iam_role_policy_attachment.reaper_basic_execution,
    aws_cloudwatch_log_group.reaper,
  ]
}

# EventBridge (CloudWatch Events) schedule firing the reaper.
resource "aws_cloudwatch_event_rule" "reaper" {
  count = local.reaper_count

  name                = "${local.reaper_slug}"
  description         = "Scheduled TTL reaper for expired artifacts on ${var.domain}."
  schedule_expression = var.reaper_schedule
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "reaper" {
  count = local.reaper_count

  rule      = aws_cloudwatch_event_rule.reaper[0].name
  target_id = "reaper-lambda"
  arn       = aws_lambda_function.reaper[0].arn
}

resource "aws_lambda_permission" "reaper" {
  count = local.reaper_count

  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reaper[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.reaper[0].arn
}

output "reaper_function_name" {
  description = "Name of the TTL reaper Lambda (null when the reaper is disabled)."
  value       = try(aws_lambda_function.reaper[0].function_name, null)
}

output "reaper_schedule_effective" {
  description = "Effective EventBridge schedule expression for the reaper (null when disabled)."
  value       = var.enable_reaper ? var.reaper_schedule : null
}
