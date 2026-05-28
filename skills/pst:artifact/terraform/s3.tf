# Private origin bucket. Name defaults to the domain (convention over config).
# No website hosting, no public access -- CloudFront reads it via OAC.
resource "aws_s3_bucket" "artifacts" {
  bucket = var.domain
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Origin Access Control: CloudFront signs every origin request with SigV4 so the
# bucket can stay fully private. This is the modern replacement for OAI.
resource "aws_cloudfront_origin_access_control" "artifacts" {
  name                              = "${var.domain}-oac"
  description                       = "OAC for ${var.domain} static site origin"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Allow only this distribution to read objects, scoped by the distribution ARN.
data "aws_iam_policy_document" "artifacts_bucket_policy" {
  statement {
    sid       = "AllowCloudFrontServicePrincipalReadOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.artifacts.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = data.aws_iam_policy_document.artifacts_bucket_policy.json
}
