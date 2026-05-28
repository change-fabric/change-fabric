# Optional, opt-in per-artifact view counter.
#
# Everything in this file is gated on var.enable_analytics and is OFF by default.
# When disabled, none of these resources are created and the related outputs are
# null. When enabled it provisions a privacy-light counter (DynamoDB + a Lambda
# Function URL the published static pages call from the browser).
#
# All analytics-specific variables and outputs live here intentionally; the rest
# of the module's variables/outputs are defined in variables.tf / outputs.tf.

variable "enable_analytics" {
  description = "Opt-in toggle for the per-artifact view-counter backend (DynamoDB + Lambda Function URL). When false, no analytics resources are created."
  type        = bool
  default     = false
}

variable "analytics_table_name" {
  description = "Name of the DynamoDB table that stores per-artifact view counts. Defaults to \"<domain>-views\"."
  type        = string
  default     = null
}

locals {
  analytics_enabled    = var.enable_analytics
  analytics_count      = var.enable_analytics ? 1 : 0
  analytics_table_name = coalesce(var.analytics_table_name, "${var.domain}-views")
}

# DynamoDB table: on-demand billing, string partition key `id` (the short
# artifact id). A numeric `views` attribute is maintained by the Lambda via an
# atomic ADD; it is not part of the key schema so it is not declared here.
resource "aws_dynamodb_table" "analytics_views" {
  count = local.analytics_count

  name         = local.analytics_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  tags = var.tags
}

# IAM role for the Lambda.
data "aws_iam_policy_document" "analytics_assume_role" {
  count = local.analytics_count

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "analytics_views" {
  count = local.analytics_count

  name               = "${var.domain}-views-lambda"
  assume_role_policy = data.aws_iam_policy_document.analytics_assume_role[0].json
  tags               = var.tags
}

# CloudWatch Logs via the AWS-managed basic execution policy.
resource "aws_iam_role_policy_attachment" "analytics_basic_execution" {
  count = local.analytics_count

  role       = aws_iam_role.analytics_views[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Least-privilege inline policy: only UpdateItem/GetItem, only on this table.
data "aws_iam_policy_document" "analytics_dynamodb" {
  count = local.analytics_count

  statement {
    effect = "Allow"
    actions = [
      "dynamodb:UpdateItem",
      "dynamodb:GetItem",
    ]
    resources = [aws_dynamodb_table.analytics_views[0].arn]
  }
}

resource "aws_iam_role_policy" "analytics_dynamodb" {
  count = local.analytics_count

  name   = "${var.domain}-views-dynamodb"
  role   = aws_iam_role.analytics_views[0].id
  policy = data.aws_iam_policy_document.analytics_dynamodb[0].json
}

# Package the lambda/ directory into a zip under .terraform-build/.
data "archive_file" "analytics_views" {
  count = local.analytics_count

  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/.terraform-build/views.zip"
}

# Log group, created explicitly so retention is bounded (Lambda would otherwise
# auto-create one with never-expire retention).
resource "aws_cloudwatch_log_group" "analytics_views" {
  count = local.analytics_count

  name              = "/aws/lambda/${var.domain}-views"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_lambda_function" "analytics_views" {
  count = local.analytics_count

  function_name    = "${var.domain}-views"
  role             = aws_iam_role.analytics_views[0].arn
  runtime          = "nodejs20.x"
  handler          = "views.handler"
  filename         = data.archive_file.analytics_views[0].output_path
  source_code_hash = data.archive_file.analytics_views[0].output_base64sha256

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.analytics_views[0].name
    }
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy.analytics_dynamodb,
    aws_iam_role_policy_attachment.analytics_basic_execution,
    aws_cloudwatch_log_group.analytics_views,
  ]
}

# Public Function URL the browser calls. CORS is scoped to the published origin.
resource "aws_lambda_function_url" "analytics_views" {
  count = local.analytics_count

  function_name      = aws_lambda_function.analytics_views[0].function_name
  authorization_type = "NONE"

  cors {
    allow_origins = ["https://${var.domain}"]
    allow_methods = ["GET"]
    allow_headers = ["content-type"]
    max_age       = 86400
  }
}

output "analytics_endpoint" {
  description = "Lambda Function URL for the view counter (null when analytics is disabled). Copy into the studio's plans.config.json as analyticsEndpoint."
  value       = try(aws_lambda_function_url.analytics_views[0].function_url, null)
}

output "analytics_table" {
  description = "DynamoDB table name backing the view counter (null when analytics is disabled)."
  value       = try(aws_dynamodb_table.analytics_views[0].name, null)
}
