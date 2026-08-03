# ---------------------------------------------------------------------------
# One HTTP API (API Gateway v2), four routes, custom domain api.changefabric.org
# (section 7). Only /transcripts carries a gateway authorizer; presence and the
# two notifications routes verify Ed25519 in-Lambda, so the gateway lets them
# through unauthenticated by design.
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "telemetry" {
  name          = "cf-telemetry-api"
  protocol_type = "HTTP"
  description   = "change-fabric backend: transcripts, presence, secret notifications"
}

# $default stage with auto-deploy: no manual deployment step, routes go live as
# they change (section 7).
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.telemetry.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId               = "$context.requestId"
      requestTime             = "$context.requestTime"
      httpMethod              = "$context.httpMethod"
      routeKey                = "$context.routeKey"
      status                  = "$context.status"
      protocol                = "$context.protocol"
      responseLength          = "$context.responseLength"
      responseLatency         = "$context.responseLatency"
      integrationStatus       = "$context.integrationStatus"
      integrationErrorMessage = "$context.integrationErrorMessage"
      sourceIp                = "$context.identity.sourceIp"
      userAgent               = "$context.identity.userAgent"
    })
  }

  # Three of the four routes are unauthenticated at the gateway by design: they
  # verify Ed25519 inside the Lambda, which means the gateway invokes the function
  # before anything checks the caller. Without a throttle, an unauthenticated
  # caller can drive Lambda invocations at the ACCOUNT concurrency limit, and no
  # function in this account sets reserved concurrency, so that starves every
  # other function in the account, including ones belonging to other workloads.
  #
  # The limits are far above real usage (this API is called by a handful of
  # developer machines) and far below anything that could exhaust the account.
  default_route_settings {
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit

    # Per-route metrics, so the alarms in account/infra can eventually be narrowed
    # from "this API returned a 5xx" to "this route did".
    detailed_metrics_enabled = true
  }
}

# ---- Shared-secret request authorizer for /transcripts (section 5.1) -----
# REQUEST authorizer, simple responses (v2.0 { isAuthorized } shape), identity
# from the stable x-api-key header, cached 300s so a repeated valid key does not
# re-invoke the authorizer.
resource "aws_apigatewayv2_authorizer" "transcript" {
  api_id                            = aws_apigatewayv2_api.telemetry.id
  name                              = "transcript-shared-secret"
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = aws_lambda_function.transcript_authorizer.invoke_arn
  identity_sources                  = ["$request.header.x-api-key"]
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true
  authorizer_result_ttl_in_seconds  = 300
}

# ---- Integrations (all AWS_PROXY, payload format 2.0) --------------------
resource "aws_apigatewayv2_integration" "transcript_ingest" {
  api_id                 = aws_apigatewayv2_api.telemetry.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.transcript_ingest.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "presence" {
  api_id                 = aws_apigatewayv2_api.telemetry.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.presence.invoke_arn
  payload_format_version = "2.0"
}

# One integration serves both notifications routes; the handler dispatches on
# path (section 7).
resource "aws_apigatewayv2_integration" "notifications" {
  api_id                 = aws_apigatewayv2_api.telemetry.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.notifications.invoke_arn
  payload_format_version = "2.0"
}

# ---- Routes --------------------------------------------------------------
resource "aws_apigatewayv2_route" "transcripts" {
  api_id             = aws_apigatewayv2_api.telemetry.id
  route_key          = "POST /transcripts"
  target             = "integrations/${aws_apigatewayv2_integration.transcript_ingest.id}"
  authorization_type = "CUSTOM"
  authorizer_id      = aws_apigatewayv2_authorizer.transcript.id
}

resource "aws_apigatewayv2_route" "presence" {
  api_id    = aws_apigatewayv2_api.telemetry.id
  route_key = "POST /presence"
  target    = "integrations/${aws_apigatewayv2_integration.presence.id}"
}

resource "aws_apigatewayv2_route" "notifications" {
  api_id    = aws_apigatewayv2_api.telemetry.id
  route_key = "POST /notifications"
  target    = "integrations/${aws_apigatewayv2_integration.notifications.id}"
}

resource "aws_apigatewayv2_route" "notifications_ack" {
  api_id    = aws_apigatewayv2_api.telemetry.id
  route_key = "POST /notifications/ack"
  target    = "integrations/${aws_apigatewayv2_integration.notifications.id}"
}

# ---- Invoke permissions --------------------------------------------------
# One grant per integrated Lambda; the /*/* source arn covers every stage+route
# the API exposes to that function (the notifications grant covers both routes).
resource "aws_lambda_permission" "apigw_transcript_ingest" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.transcript_ingest.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.telemetry.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_presence" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.presence.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.telemetry.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_notifications" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notifications.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.telemetry.execution_arn}/*/*"
}

# The gateway must also be allowed to invoke the authorizer Lambda; its source
# arn is the authorizer, not a route.
resource "aws_lambda_permission" "apigw_authorizer" {
  statement_id  = "AllowApiGatewayInvokeAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.transcript_authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.telemetry.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.transcript.id}"
}
