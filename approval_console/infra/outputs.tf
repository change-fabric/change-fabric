output "function_url" {
  description = "The console base URL. Its host is the WebAuthn rpId: record it and never recreate the function or URL."
  value       = aws_lambda_function_url.console.function_url
}

output "rp_id" {
  description = "The WebAuthn relying party id (the function URL host)."
  value       = local.rp_id
}

output "function_name" {
  description = "The Lambda function name."
  value       = aws_lambda_function.console.function_name
}

output "table_name" {
  description = "The single DynamoDB table."
  value       = aws_dynamodb_table.console.name
}

output "seed_key_arn" {
  description = "KMS key that encrypts TOTP seeds (encryption context machine_id)."
  value       = aws_kms_key.seeds.arn
}

output "receipt_key_arn" {
  description = "KMS signing key for receipts. Fetch its public key with kms:GetPublicKey at enroll."
  value       = aws_kms_key.receipts.arn
}

output "operator_policy_arn" {
  description = "Attach this to the role or permission set behind the profile that runs the CLI verbs."
  value       = aws_iam_policy.operator.arn
}

output "prod_claim_role_arn" {
  description = "Role the prod runner's cf-prod.yml assumes by GitHub OIDC to record an approval as consumed (conditional PutItem on CLAIM# only)."
  value       = aws_iam_role.prod_claim.arn
}

output "claim_table_name" {
  description = "Table that holds CLAIM#<request_id> items (same table as the console)."
  value       = aws_dynamodb_table.console.name
}
