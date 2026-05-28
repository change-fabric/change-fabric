output "distribution_id" {
  description = "CloudFront distribution id (used by scripts/publish.py for invalidations)."
  value       = aws_cloudfront_distribution.artifacts.id
}

output "distribution_domain_name" {
  description = "CloudFront distribution domain name (e.g. dxxxx.cloudfront.net)."
  value       = aws_cloudfront_distribution.artifacts.domain_name
}

output "bucket_name" {
  description = "Name of the private origin S3 bucket (the s3 sync target)."
  value       = aws_s3_bucket.artifacts.id
}

output "certificate_arn" {
  description = "ARN of the validated ACM certificate serving the distribution."
  value       = aws_acm_certificate_validation.artifacts.certificate_arn
}

output "published_url_base" {
  description = "Public base URL the site is served at."
  value       = "https://${var.domain}"
}
