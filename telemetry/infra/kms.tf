# One customer-managed key encrypts every table and the transcript bucket
# (section 8). A single CMK keeps the key policy and the per-Lambda kms grants in
# one place; the four tables and the bucket all reference this same key arn.
resource "aws_kms_key" "backend" {
  description             = "change-fabric backend CMK: all DynamoDB tables and the cf-transcripts bucket"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  # Default-shape key policy: the account root holds the key so that IAM policies
  # (the per-Lambda inline grants in iam.tf) are what actually govern kms:Decrypt
  # / GenerateDataKey. We do NOT enumerate service principals here; DynamoDB and
  # S3 use the key on behalf of a caller that already holds the IAM grant.
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
}

resource "aws_kms_alias" "backend" {
  name          = "alias/cf-backend"
  target_key_id = aws_kms_key.backend.key_id
}
