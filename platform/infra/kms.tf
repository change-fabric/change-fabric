# One customer-managed key encrypts the shared Postgres instance's storage (and
# its automated backups and snapshots, which inherit the instance's key). A
# single CMK keeps the key policy in one place; later phases that need envelope
# encryption reference this same key arn out of the outputs.
resource "aws_kms_key" "platform" {
  description             = "change-fabric platform CMK: RDS storage encryption for the shared cf-platform instance"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  # Default-shape key policy: the account root holds the key, so IAM policies are
  # what actually govern kms:Decrypt / GenerateDataKey. No cross-account grants
  # and no enumerated service principals; RDS uses the key on behalf of a caller
  # that already holds the IAM grant.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EnableIAMUserPermissions"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })

  tags = merge(local.tags, { Name = local.name_prefix })
}

resource "aws_kms_alias" "platform" {
  name          = "alias/cf-platform"
  target_key_id = aws_kms_key.platform.key_id
}
