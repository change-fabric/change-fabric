# One customer-managed key encrypts the shared Postgres instance's storage (and
# its automated backups and snapshots, which inherit the instance's key) and,
# from phase 5, the artifacts bucket's objects. A single CMK keeps the key policy
# in one place; later phases that need envelope encryption reference this same
# key arn out of the outputs.
resource "aws_kms_key" "platform" {
  description             = "change-fabric platform CMK: RDS storage encryption for the shared cf-platform instance"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  # Mostly the default shape: the account root holds the key, so IAM policies are
  # what actually govern kms:Decrypt / GenerateDataKey for every principal that
  # has an IAM identity. RDS and the API's Lambda role both fall under that
  # first statement.
  #
  # CloudFront does not. When it reads the artifacts bucket through an origin
  # access control it acts as the `cloudfront.amazonaws.com` service principal,
  # which has no IAM identity for the root statement to delegate to, so without
  # the second statement every object fetch would fail to decrypt and the
  # artifacts host would answer 502 for content that is present and correct.
  #
  # The grant is narrowed three ways rather than left open: to decryption only,
  # to requests this account originated, and to requests arriving through S3.
  # The distribution is not named, because doing so would make this key's policy
  # depend on a distribution that depends on the bucket that depends on this key.
  # Which distribution may actually read the bucket is settled where it belongs,
  # in the bucket policy in artifacts.tf, by exact ARN.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableIAMUserPermissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudFrontDecryptViaS3"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "kms:Decrypt"
        Resource  = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
            "kms:ViaService"    = "s3.us-east-1.amazonaws.com"
          }
        }
      },
    ]
  })

  tags = merge(local.tags, { Name = local.name_prefix })
}

resource "aws_kms_alias" "platform" {
  name          = "alias/cf-platform"
  target_key_id = aws_kms_key.platform.key_id
}
