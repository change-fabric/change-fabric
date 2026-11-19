# ---------------------------------------------------------------------------
# Seed key: encrypts each machine's TOTP seed at the application level. Rotation
# on. Decrypt is reachable only from the Lambda role and only with the machine_id
# encryption context: the key policy denies everyone else and denies any call
# that omits the context.
# ---------------------------------------------------------------------------
resource "aws_kms_key" "seeds" {
  description             = "approval console: TOTP seeds, application-level encryption with a machine_id context"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableIAMUserPermissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        # Nobody but the function can read a seed back, not even an account admin
        # with an allow in IAM. Changing this needs a key policy edit, which
        # shows in CloudTrail.
        Sid       = "OnlyTheFunctionDecrypts"
        Effect    = "Deny"
        Principal = { AWS = "*" }
        Action    = ["kms:Decrypt", "kms:ReEncryptFrom"]
        Resource  = "*"
        Condition = {
          StringNotEquals = { "aws:PrincipalArn" = aws_iam_role.console.arn }
        }
      },
      {
        Sid       = "ContextRequired"
        Effect    = "Deny"
        Principal = { AWS = "*" }
        Action    = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:ReEncrypt*"]
        Resource  = "*"
        Condition = {
          Null = { "kms:EncryptionContext:${local.context_key}" = "true" }
        }
      },
    ]
  })
}

resource "aws_kms_alias" "seeds" {
  name          = "alias/${local.name}-seeds"
  target_key_id = aws_kms_key.seeds.key_id
}

# ---------------------------------------------------------------------------
# Receipt key: the console signs each accepted approval with it. Asymmetric keys
# cannot rotate, so a new key means re-pinning on every machine. Only the Lambda
# may Sign; the operator policy grants GetPublicKey for enrollment.
# ---------------------------------------------------------------------------
resource "aws_kms_key" "receipts" {
  description              = "approval console: signs approval receipts"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_NIST_P256"
  deletion_window_in_days  = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableIAMUserPermissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "OnlyTheFunctionSigns"
        Effect    = "Deny"
        Principal = { AWS = "*" }
        Action    = "kms:Sign"
        Resource  = "*"
        Condition = {
          StringNotEquals = { "aws:PrincipalArn" = aws_iam_role.console.arn }
        }
      },
    ]
  })
}

resource "aws_kms_alias" "receipts" {
  name          = "alias/${local.name}-receipts"
  target_key_id = aws_kms_key.receipts.key_id
}
