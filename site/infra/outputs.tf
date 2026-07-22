output "site_bucket" {
  description = "S3 bucket holding the built site."
  value       = aws_s3_bucket.site.bucket
}

output "www_distribution_id" {
  description = "CloudFront distribution serving the canonical www site."
  value       = aws_cloudfront_distribution.www.id
}

output "apex_distribution_id" {
  description = "CloudFront distribution redirecting the apex to www."
  value       = aws_cloudfront_distribution.apex.id
}

output "www_url" {
  description = "Canonical site URL."
  value       = "https://${var.www_domain}"
}

output "apex_url" {
  description = "Apex URL, which redirects to the canonical www URL."
  value       = "https://${var.domain}"
}

output "deploy_site_role_arn" {
  description = "IAM role deploy-site.yml assumes via OIDC to publish the site."
  value       = aws_iam_role.deploy_site.arn
}
