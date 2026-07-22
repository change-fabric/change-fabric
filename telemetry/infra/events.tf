# ---------------------------------------------------------------------------
# The secret_scanner's two triggers (section 6.4, section 8): the DynamoDB stream
# for freshness and the hourly EventBridge sweep as the durable catch-all. One
# Lambda, two front ends.
# ---------------------------------------------------------------------------

# Stream path: every new cf-telemetry item reaches the scanner within seconds.
# LATEST (not TRIM_HORIZON) because backfilled/older items are covered by the
# sweep, not by replaying the whole stream. bisect_batch_on_function_error plus a
# bounded retry keeps one poison record from wedging a batch forever; the small
# batching window trades a little latency for fewer invocations.
resource "aws_lambda_event_source_mapping" "telemetry_stream" {
  event_source_arn                   = aws_dynamodb_table.telemetry.stream_arn
  function_name                      = aws_lambda_function.secret_scanner.arn
  starting_position                  = "LATEST"
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5
  maximum_retry_attempts             = 3
  bisect_batch_on_function_error     = true
}

# Sweep path: the hourly catch-all that drains anything the stream did not mark
# scanned (section 6.4).
resource "aws_cloudwatch_event_rule" "secret_sweep" {
  name                = "cf-secret-sweep"
  description         = "Hourly durable catch-all sweep of unscanned transcripts"
  schedule_expression = "rate(1 hour)"
}

resource "aws_cloudwatch_event_target" "secret_sweep" {
  rule      = aws_cloudwatch_event_rule.secret_sweep.name
  target_id = "secret-scanner"
  arn       = aws_lambda_function.secret_scanner.arn
}

# EventBridge needs explicit permission to invoke the scanner.
resource "aws_lambda_permission" "secret_sweep" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.secret_scanner.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.secret_sweep.arn
}
