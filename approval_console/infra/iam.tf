data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "console" {
  name               = "${local.name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# Least privilege: this table, the two keys, the two DM parameters, and this
# function's own log group. No wildcards on resources, no table deletes beyond
# the item level, nothing outside this root.
resource "aws_iam_role_policy" "console" {
  name = "inline"
  role = aws_iam_role.console.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Table"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:ConditionCheckItem",
          "dynamodb:Query",
        ]
        Resource = aws_dynamodb_table.console.arn
      },
      {
        # Decrypt only, and only with a machine_id context on the call.
        Sid      = "DecryptSeeds"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.seeds.arn
        Condition = {
          Null = { "kms:EncryptionContext:${local.context_key}" = "false" }
        }
      },
      {
        Sid      = "SignReceipts"
        Effect   = "Allow"
        Action   = "kms:Sign"
        Resource = aws_kms_key.receipts.arn
      },
      {
        Sid    = "DirectMessageParameters"
        Effect = "Allow"
        Action = "ssm:GetParameter"
        Resource = [
          "arn:${data.aws_partition.current.partition}:ssm:us-east-1:${data.aws_caller_identity.current.account_id}:parameter${var.dm_token_param}",
          "arn:${data.aws_partition.current.partition}:ssm:us-east-1:${data.aws_caller_identity.current.account_id}:parameter${var.dm_recipient_param}",
        ]
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.console.arn}:*"
      },
    ]
  })
}

# What the human's own AWS profile needs for the CLI verbs (enroll, revoke,
# recover, status). Terraform creates the policy and never attaches it: attach
# it to the role or permission set the profile uses. An account admin already
# has all of this.
resource "aws_iam_policy" "operator" {
  name        = "${local.name}-operator"
  description = "CLI access to the approval console: bootstrap tokens, seed upload, credential reads and revokes, receipt public key."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The bootstrap token and the per-machine rows the CLI seeds at enroll.
        # The handler's own condition (attribute_not_exists) makes the token
        # single-use; this scopes the CLI to those partitions only.
        Sid      = "SeedRows"
        Effect   = "Allow"
        Action   = "dynamodb:PutItem"
        Resource = aws_dynamodb_table.console.arn
        Condition = {
          "ForAllValues:StringLike" = { "dynamodb:LeadingKeys" = ["BOOT#*", "M#*", "RECOVERY#*"] }
        }
      },
      {
        # Pin, list, revoke and recover read and delete the credential rows only.
        Sid      = "Credentials"
        Effect   = "Allow"
        Action   = ["dynamodb:Query", "dynamodb:GetItem", "dynamodb:DeleteItem"]
        Resource = aws_dynamodb_table.console.arn
        Condition = {
          "ForAllValues:StringEquals" = { "dynamodb:LeadingKeys" = ["CRED"] }
        }
      },
      {
        Sid      = "EncryptSeed"
        Effect   = "Allow"
        Action   = "kms:Encrypt"
        Resource = aws_kms_key.seeds.arn
        Condition = {
          Null = { "kms:EncryptionContext:${local.context_key}" = "false" }
        }
      },
      {
        Sid      = "ReceiptPublicKey"
        Effect   = "Allow"
        Action   = "kms:GetPublicKey"
        Resource = aws_kms_key.receipts.arn
      },
    ]
  })
}
