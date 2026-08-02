# Every later phase reads this root's state with a terraform_remote_state data
# source against key changefabric-platform/terraform.tfstate, so these outputs
# are the phase boundary's contract. No secret is published here: the SSM
# parameter names are the handle, and the values stay in SSM.

output "vpc_id" {
  description = "Platform VPC (10.40.0.0/16, no internet gateway and no NAT)."
  value       = aws_vpc.platform.id
}

output "private_subnet_id_a" {
  description = "Private subnet in us-east-1a. Also the AZ hosting the SES SMTP interface endpoint."
  value       = aws_subnet.private["a"].id
}

output "private_subnet_id_b" {
  description = "Private subnet in us-east-1b. Present so the DB subnet group spans two AZs."
  value       = aws_subnet.private["b"].id
}

output "private_subnet_ids" {
  description = "Both private subnet ids, in the order a Lambda VPC config wants them."
  value       = [aws_subnet.private["a"].id, aws_subnet.private["b"].id]
}

output "lambda_security_group_id" {
  description = "Egress-only group for platform Lambda workloads. Attach later phases' functions to this group to reach Postgres and the SES endpoint."
  value       = aws_security_group.lambda.id
}

output "rds_security_group_id" {
  description = "Group on the shared Postgres instance. Accepts 5432 from the Lambda group only."
  value       = aws_security_group.rds.id
}

output "rds_endpoint" {
  description = "Shared cf-platform instance endpoint (host:port)."
  value       = aws_db_instance.platform.endpoint
}

output "rds_address" {
  description = "Shared cf-platform instance hostname, without the port."
  value       = aws_db_instance.platform.address
}

output "rds_port" {
  description = "Shared cf-platform instance port."
  value       = aws_db_instance.platform.port
}

output "kms_key_arn" {
  description = "Platform CMK arn (alias/cf-platform). Encrypts the RDS instance's storage, backups and snapshots."
  value       = aws_kms_key.platform.arn
}

output "acm_certificate_arn" {
  description = "Validated wildcard certificate for *.staging.changefabric.org, in us-east-1."
  value       = aws_acm_certificate_validation.staging.certificate_arn
}

output "hosted_zone_id" {
  description = "Existing changefabric.org hosted zone, owned by site/infra and only read here."
  value       = data.aws_route53_zone.primary.zone_id
}

output "ses_smtp_vpc_endpoint_id" {
  description = "Interface endpoint giving the VPC a private path to SES SMTP, which is why the VPC needs no NAT gateway."
  value       = aws_vpc_endpoint.email_smtp.id
}

output "ssm_parameter_names" {
  description = "SSM SecureString parameter names later phases read. Names only; the values never leave SSM."
  value = {
    db_master_password  = aws_ssm_parameter.db_master_password.name
    staging_db_password = aws_ssm_parameter.staging_db_password.name
    staging_auth_secret = aws_ssm_parameter.staging_better_auth_secret.name
    staging_basic_auth  = aws_ssm_parameter.staging_basic_auth_credential.name
  }
}

output "staging_database_name" {
  description = "Postgres database holding the staging environment inside the shared instance."
  value       = local.staging_database
}

output "staging_database_role" {
  description = "Postgres login role the staging application connects as."
  value       = local.staging_role
}

output "api_domain_name" {
  description = "Public host the staging API answers on."
  value       = aws_apigatewayv2_domain_name.api.domain_name
}

output "api_endpoint" {
  description = "API Gateway's own execute-api endpoint, behind the custom domain. Useful for isolating a DNS problem from a gateway problem."
  value       = aws_apigatewayv2_api.api.api_endpoint
}

output "api_function_name" {
  description = "Lambda serving the staging API."
  value       = aws_lambda_function.api.function_name
}

output "migrate_function_name" {
  description = "Maintenance Lambda. Invoke it directly to apply migrations or read a row back; nothing routes to it."
  value       = aws_lambda_function.migrate.function_name
}

output "ses_from_address" {
  description = "From address the staging API sends transactional mail as."
  value       = local.ses_from_address
}

# Only populated during a bootstrap run. This is the target an SSM port-forward
# points at; it is null whenever the bastion is torn down, which is its normal
# state.
output "bastion_instance_id" {
  description = "Ephemeral bootstrap bastion instance id, or null when provision_bastion is false."
  value       = var.provision_bastion ? aws_instance.bastion[0].id : null
}
