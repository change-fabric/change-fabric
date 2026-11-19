# One single-table design for every machine in the account (plan, per-machine
# rows). pk/sk layout: CRED/<credential id>, M#<machine>/META, SEED,
# REQ#<request>, REC#<request>, BOOT#<token hash>/BOOT. On demand, point in time
# recovery on. Encrypted with the AWS-owned key: the customer key below is used
# only for application-level seed encryption, so its machine_id encryption-context
# rule never collides with DynamoDB's own use of a key.
resource "aws_dynamodb_table" "console" {
  name         = local.name
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

  # Cleanup only. The handler enforces every deadline against its own clock; TTL
  # deletion can lag by up to two days and is never a deadline.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }
}
