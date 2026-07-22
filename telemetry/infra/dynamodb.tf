# ---------------------------------------------------------------------------
# Four DynamoDB tables, one concern each (section 2). All on-demand, all CMK-
# encrypted, all with point-in-time recovery. The retention story differs on
# purpose: three tables carry an expires_at TTL; cf-teams carries none, because
# it is the durable identity registry and the sole 90-day-purge exemption
# (section 2.3, section 11).
# ---------------------------------------------------------------------------

# cf-telemetry: one transcript's metadata/pointer plus its scan state. This is
# the only table with a stream and a GSI, because it is the input to the secret
# scanner (Capability C): the stream feeds freshness, the sparse gsi-unscanned
# is the hourly sweep's work queue (section 2.1, section 6.4).
resource "aws_dynamodb_table" "telemetry" {
  name         = local.telemetry_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }
  # Indexed by the sparse GSI below. scan_status is written as the literal
  # "pending" on insert and flipped to "scanned"; emitted_at is the ISO8601
  # stamp the sweep pages through in ascending (chronological) order.
  attribute {
    name = "scan_status"
    type = "S"
  }
  attribute {
    name = "emitted_at"
    type = "S"
  }

  # 90-day horizon for transcript metadata; the Lambda writes expires_at =
  # emitted_at + 90d (epoch seconds) per row (section 11).
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  # NEW_IMAGE is all the scanner needs off the stream: it reads the freshly
  # inserted item (or fetches the S3 body the item points at) and never needs
  # the prior image (section 8).
  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"

  # The sparse work queue. Because DynamoDB only projects an item when the hash
  # attribute is present and we only ever write the literal "pending" as the
  # queried value, this index holds exactly the not-yet-scanned transcripts, in
  # emitted_at order. Projection is the few attributes the sweep needs to fetch a
  # body and route a finding without a second GetItem (section 2.1).
  global_secondary_index {
    name            = local.unscanned_index
    hash_key        = "scan_status"
    range_key       = "emitted_at"
    projection_type = "INCLUDE"
    non_key_attributes = [
      "transcript_location",
      "transcript_s3_key",
      "team_id",
      "contributor_id",
    ]
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.backend.arn
  }

  point_in_time_recovery {
    enabled = true
  }
}

# cf-presence: ephemeral "who on my team is editing this file right now"
# (section 2.2). TTL is a 15-minute horizon the Lambda sets per row; unrelated to
# the 90-day policy, just far faster.
resource "aws_dynamodb_table" "presence" {
  name         = local.presence_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.backend.arn
  }

  point_in_time_recovery {
    enabled = true
  }
}

# cf-teams: the durable team_id -> Ed25519 public key registry (section 2.3).
# Deliberately NO ttl block at all: an item without the attribute is never an
# expiry candidate, which is what makes this registry durable by construction and
# the single exemption from the 90-day purge (section 11). Rows are seeded out of
# band by cf-team-init; Terraform owns the empty table, not its contents.
resource "aws_dynamodb_table" "teams" {
  name         = local.teams_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.backend.arn
  }

  point_in_time_recovery {
    enabled = true
  }
}

# cf-notifications: one secret-scan finding plus its acknowledgement (section
# 2.4). 90-day TTL anchored to the finding's own created_at (the scanner writes
# expires_at per row), so a late-swept finding keeps its full audit window even
# if the referenced transcript has aged out. Rows are written only by the scanner
# at runtime.
resource "aws_dynamodb_table" "notifications" {
  name         = local.notifications_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.backend.arn
  }

  point_in_time_recovery {
    enabled = true
  }
}
