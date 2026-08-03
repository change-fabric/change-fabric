# ---------------------------------------------------------------------------
# Log groups, declared rather than left to the Lambda service.
#
# Nothing here created a log group, so all five were created implicitly on first
# invoke with the service default retention, which is never. `cf-secret-scanner`
# runs hourly on the EventBridge schedule in events.tf and had accumulated 238 MB
# of logs that nothing would ever delete:
#
#   238398  /aws/lambda/cf-secret-scanner         None
#     4175  /aws/lambda/cf-transcript-ingest      None
#     2331  /aws/lambda/cf-notifications-api      None
#     1059  /aws/lambda/cf-transcript-authorizer  None
#      757  /aws/lambda/cf-presence               None
#
# platform/infra sets 30 days on its own functions; this root had simply never
# been given the same treatment.
#
# THESE GROUPS ALREADY EXIST. They must be imported before the first apply, or
# Terraform will fail with ResourceAlreadyExistsException. See README.md.
#
# Setting retention deletes events older than the window. That is the point (an
# hourly job's logs from two months ago are not going to be read), but it is a
# deletion, so it is said out loud rather than left to be discovered.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "lambda" {
  for_each = local.fn

  name              = "/aws/lambda/${each.value}"
  retention_in_days = var.log_retention_days

  tags = { Name = "/aws/lambda/${each.value}" }
}

# ---------------------------------------------------------------------------
# Access logs for the API.
#
# The stage carried no access_log_settings, so there was no record of who called
# the production API or what it answered, only whatever each Lambda chose to
# print. An access log is the difference between "a user reports an error" and
# "here is the request, its status, its latency and its integration error".
#
# The format is the standard JSON one from the API Gateway documentation, plus
# integrationErrorMessage, which is the field that distinguishes "the Lambda
# returned a 500" from "the Lambda never answered at all", the latter being how a
# missing network path presents from outside.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/cf-telemetry-api"
  retention_in_days = var.log_retention_days

  tags = { Name = "/aws/apigateway/cf-telemetry-api" }
}
