# ---------------------------------------------------------------------------
# One notification path for everything in this root.
#
# Before this, the account had exactly one CloudWatch alarm (pay-app-5xx, from an
# unrelated workload) and no alarm at all on the RDS instance, any Lambda, either
# API, or any CloudFront distribution. Every alarm, budget threshold and cost
# anomaly below publishes here, so there is one subscription to confirm and one
# place to add a second channel later.
# ---------------------------------------------------------------------------

# The topic is encrypted, which for SNS means the publishers have to be named in
# the key policy: an AWS service publishing to an encrypted topic calls KMS as
# itself, not as an IAM identity the account-root statement can delegate to. Three
# services publish here and each needs GenerateDataKey, not just Encrypt, because
# SNS uses envelope encryption.
resource "aws_kms_key" "alerts" {
  description             = "change-fabric account alerts: SNS topic encryption for alarms, budgets and cost anomalies"
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
        Sid    = "AllowAlarmPublishersToUseTheKey"
        Effect = "Allow"
        Principal = {
          Service = [
            "cloudwatch.amazonaws.com",
            "budgets.amazonaws.com",
            "costalerts.amazonaws.com",
          ]
        }
        Action   = ["kms:GenerateDataKey*", "kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })

  tags = merge(local.tags, { Name = "cf-alerts" })
}

resource "aws_kms_alias" "alerts" {
  name          = "alias/cf-alerts"
  target_key_id = aws_kms_key.alerts.key_id
}

resource "aws_sns_topic" "alerts" {
  name              = "cf-alerts"
  display_name      = "change-fabric alerts"
  kms_master_key_id = aws_kms_key.alerts.arn

  tags = local.tags
}

# Publish rights for the same three services. The account-root principal already
# holds every SNS action through IAM, so this policy only adds what IAM cannot
# express: a service principal with no IAM identity behind it. Each grant is
# conditioned on the source account so another account's alarm cannot publish here.
resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAccountOwnerFullControl"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        # Enumerated rather than "SNS:*". A topic policy is not an IAM policy: SNS
        # validates every action against the set that is meaningful on a topic and
        # rejects the whole document with "Policy statement action out of service
        # scope" if a wildcard widens it past that set. This is the same list the
        # console writes as the default owner statement.
        Action = [
          "SNS:GetTopicAttributes",
          "SNS:SetTopicAttributes",
          "SNS:AddPermission",
          "SNS:RemovePermission",
          "SNS:DeleteTopic",
          "SNS:Subscribe",
          "SNS:ListSubscriptionsByTopic",
          "SNS:Publish",
        ]
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Sid    = "AllowAlarmPublishers"
        Effect = "Allow"
        Principal = {
          Service = [
            "cloudwatch.amazonaws.com",
            "budgets.amazonaws.com",
            "costalerts.amazonaws.com",
          ]
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.alerts.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })
}

# AWS mails a confirmation link on creation and the subscription stays
# PendingConfirmation until it is clicked. Terraform reports the subscription as
# created either way, so a green apply is NOT proof that a single alert can be
# delivered. Confirming it is the one manual step this root needs; see README.md.
resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
