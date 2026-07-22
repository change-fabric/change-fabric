output "api_url" {
  description = "Public API base URL on the custom domain (all four routes hang off this)."
  value       = "https://${local.api_domain}"
}

output "api_gateway_endpoint" {
  description = "Raw API Gateway execute-api endpoint, useful before DNS/cert propagation completes."
  value       = aws_apigatewayv2_api.telemetry.api_endpoint
}

output "telemetry_table_name" {
  description = "cf-telemetry table (transcript metadata + scan state)."
  value       = aws_dynamodb_table.telemetry.name
}

output "presence_table_name" {
  description = "cf-presence table (live file claims)."
  value       = aws_dynamodb_table.presence.name
}

output "teams_table_name" {
  description = "cf-teams table (durable team_id -> public key registry)."
  value       = aws_dynamodb_table.teams.name
}

output "notifications_table_name" {
  description = "cf-notifications table (secret-scan findings + acks)."
  value       = aws_dynamodb_table.notifications.name
}

output "transcripts_bucket_name" {
  description = "cf-transcripts bucket (offloaded transcript bodies)."
  value       = aws_s3_bucket.transcripts.bucket
}

output "kms_key_arn" {
  description = "Backend CMK arn (encrypts all four tables and the bucket)."
  value       = aws_kms_key.backend.arn
}

output "presence_ecr_repository_url" {
  description = "Push the presence container image here, then set presence_image_uri to <this>:<tag>."
  value       = aws_ecr_repository.presence.repository_url
}

output "notifications_ecr_repository_url" {
  description = "Push the notifications container image here, then set notifications_image_uri to <this>:<tag>."
  value       = aws_ecr_repository.notifications.repository_url
}
