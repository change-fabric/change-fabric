# ---------------------------------------------------------------------------
# cf-transcripts: the raw transcript bodies too large to inline into DynamoDB
# (the normal case, section 2.1). Private, CMK-encrypted, versioned, and lifecycle
# -purged at the same 90-day horizon as its cf-telemetry pointer.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "transcripts" {
  bucket = local.transcripts_bucket
}

# Never public. All four flags on: the API Gateway + ingest Lambda are the only
# writer and the scanner the only reader, both via IAM (section 11).
resource "aws_s3_bucket_public_access_block" "transcripts" {
  bucket                  = aws_s3_bucket.transcripts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning is on so an overwrite never destroys a prior body outright. It also
# forces the noncurrent-version rule below: without it a plain expiration on a
# versioned bucket only writes a delete marker and strands the old versions.
resource "aws_s3_bucket_versioning" "transcripts" {
  bucket = aws_s3_bucket.transcripts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "transcripts" {
  bucket = aws_s3_bucket.transcripts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.backend.arn
    }
    bucket_key_enabled = true
  }
}

# The load-bearing partner to the cf-telemetry TTL (section 8, section 11).
# DynamoDB TTL only deletes the pointer item; it can never touch the S3 object
# the pointer names, so without this rule an offloaded body would outlive its
# pointer forever as an orphan no TTL can reach. Both are anchored to ingest
# time, so pointer and body age out together at 90 days.
resource "aws_s3_bucket_lifecycle_configuration" "transcripts" {
  bucket = aws_s3_bucket.transcripts.id

  # Versioning must be settled before a lifecycle config that references
  # noncurrent versions applies cleanly.
  depends_on = [aws_s3_bucket_versioning.transcripts]

  rule {
    id     = "purge-transcripts-90d"
    status = "Enabled"

    # Whole bucket: every transcript body follows the same 90-day horizon.
    filter {}

    # Current versions age out at 90 days.
    expiration {
      days = 90
    }

    # Noncurrent versions age out at 90 days too (mandatory because versioning is
    # on; see the versioning resource above).
    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    # Reap abandoned multipart uploads so a failed large-transcript PUT does not
    # linger and accrue storage.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
