# The package is staged by build.sh (handler, vendored shared files, gems) and
# zipped here at plan time. output_base64sha256 drives source_code_hash so a
# rebuilt package redeploys.
data "archive_file" "console" {
  type        = "zip"
  source_dir  = "${path.module}/${var.package_dir}"
  output_path = "${path.module}/build/console.zip"
}

resource "aws_cloudwatch_log_group" "console" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = var.log_retention_days
}

# NEVER RECREATE the function or its URL. The URL host is the WebAuthn rpId;
# a new URL orphans every registered passkey. prevent_destroy makes a plan that
# would replace either one fail instead of apply.
resource "aws_lambda_function" "console" {
  function_name    = local.name
  role             = aws_iam_role.console.arn
  runtime          = "ruby3.4"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.console.output_path
  source_code_hash = data.archive_file.console.output_base64sha256
  memory_size      = 256
  timeout          = 10

  # Bounds parallelism, not spend. 0 stops the service.
  reserved_concurrent_executions = var.reserved_concurrency

  environment {
    variables = {
      TABLE_NAME         = aws_dynamodb_table.console.name
      SEED_KEY_ID        = aws_kms_key.seeds.arn
      RECEIPT_KEY_ID     = aws_kms_key.receipts.arn
      DM_TOKEN_PARAM     = var.dm_token_param
      DM_RECIPIENT_PARAM = var.dm_recipient_param
    }
  }

  depends_on = [aws_cloudwatch_log_group.console, aws_iam_role_policy.console]

  lifecycle {
    prevent_destroy = true
  }
}

# Auth NONE: the handler authenticates every route that is not the page GET or a
# registration request (machine signature, passkey, TOTP). No CORS: the page is
# served from the same origin it posts to.
resource "aws_lambda_function_url" "console" {
  function_name      = aws_lambda_function.console.function_name
  authorization_type = "NONE"

  lifecycle {
    prevent_destroy = true
  }
}

# A public function URL needs both permissions: invoke through the URL, and
# invoke at all when called via the URL. The second is scoped to URL calls, so a
# direct lambda:Invoke from an arbitrary AWS principal stays denied. Needs the
# v6 provider (invoked_via_function_url).
resource "aws_lambda_permission" "url" {
  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.console.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "url_invoke" {
  statement_id             = "AllowInvokeViaFunctionUrl"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.console.function_name
  principal                = "*"
  invoked_via_function_url = true
}
