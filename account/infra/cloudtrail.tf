# ---------------------------------------------------------------------------
# An audit trail that outlives 90 days.
#
# `aws cloudtrail describe-trails` returned an empty trailList: the account had no
# trail at all. That is not the same as having no history, because CloudTrail
# Event history retains management events for 90 days whether a trail exists or
# not, but it is the difference between a 90-day console-only window and a
# durable, integrity-validated record you can grep. With no trail there is no
# threat model worth the name and no way to answer "who changed that" about
# anything older than a quarter.
#
# One trail, management events only. Data events (every S3 object read, every
# Lambda invoke) are where CloudTrail gets expensive and are deliberately off: the
# question this trail exists to answer is who changed the shape of the estate, not
# who read which object.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "trail" {
  bucket = "changefabric-cloudtrail-${data.aws_caller_identity.current.account_id}"

  tags = merge(local.tags, { Name = "changefabric-cloudtrail" })
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket = aws_s3_bucket.trail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "trail" {
  bucket = aws_s3_bucket.trail.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 rather than the CMK in alerts.tf, and the choice is deliberate. A KMS
# CMK on a CloudTrail bucket means every principal who may ever need to READ the
# log during an incident also needs kms:Decrypt on that key, which is one more
# thing to have got right in advance of the incident. The trail's own log file
# validation below is what makes these files trustworthy; the encryption here is
# about the data at rest, and SSE-S3 is enough for that with none of the
# key-policy failure modes.
resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# A year of history, then gone. Management-event volume in an account this size is
# tiny, so the transition to a colder class earns less than it costs in per-object
# transition charges; expiry alone is the right lever.
resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    id     = "expire-trail-objects"
    status = "Enabled"

    filter {}

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# The service principal grant CloudTrail needs to write here, narrowed to this
# account's own trail by SourceArn so no other account's trail can deposit logs in
# this bucket, and denying anything that arrives without TLS.
resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.trail.arn
        Condition = {
          StringEquals = {
            "aws:SourceArn" = local.trail_arn
          }
        }
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.trail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = local.trail_arn
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.trail.arn,
          "${aws_s3_bucket.trail.arn}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
    ]
  })
}

locals {
  # Named rather than referenced, because the bucket policy has to name the trail
  # and the trail has to name the bucket. Constructing the arn from the known name
  # breaks that cycle without weakening the condition.
  trail_name = "changefabric-management"
  trail_arn  = "arn:${data.aws_partition.current.partition}:cloudtrail:us-east-1:${data.aws_caller_identity.current.account_id}:trail/changefabric-management"
}

resource "aws_cloudtrail" "management" {
  name           = local.trail_name
  s3_bucket_name = aws_s3_bucket.trail.id

  # Multi-region and global-service events both on. A single-region trail is the
  # classic gap: an action taken in a region nobody watches is exactly the action
  # worth having a record of, and IAM, CloudFront and Route53 only ever report
  # into us-east-1 as global events.
  is_multi_region_trail         = true
  include_global_service_events = true

  # Every file gets a hash chained into a signed digest, so a later edit or
  # deletion is detectable rather than merely unlikely.
  enable_log_file_validation = true

  tags = local.tags

  depends_on = [aws_s3_bucket_policy.trail]
}
