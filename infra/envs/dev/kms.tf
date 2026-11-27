# One encryption key usable in BOTH regions (a multi-Region key).
# DynamoDB Global Tables need a key in each replica's region; a multi-Region key
# gives them the same key material, so data encrypted in one region decrypts in the other.

data "aws_iam_policy_document" "kms" {
  #checkov:skip=CKV_AWS_111:Key policy, not an IAM policy: "Resource: *" means this key only (AWS default key policy)
  #checkov:skip=CKV_AWS_356:Key policy, not an IAM policy: "Resource: *" means this key only (AWS default key policy)
  #checkov:skip=CKV_AWS_109:Key policy, not an IAM policy: delegates key access to IAM, the AWS default
  # Account administrators manage the key through IAM (the standard default policy)
  statement {
    sid       = "EnableIAMPolicies"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # CloudWatch Logs may use this key, but ONLY for ticketrush-dev log groups
  statement {
    sid       = "AllowCloudWatchLogsForTicketRushLogGroups"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.us-east-1.amazonaws.com", "logs.us-west-2.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values = [
        "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/ticketrush-dev-*",
        "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/apigateway/ticketrush-dev-*",
      ]
    }
  }
}

resource "aws_kms_key" "data" {
  description             = "${local.name} data encryption (DynamoDB, SQS, S3, logs)"
  multi_region            = true
  enable_key_rotation     = true # rotate the key material yearly
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "data" {
  name          = "alias/${local.name}-data"
  target_key_id = aws_kms_key.data.key_id
}

resource "aws_kms_replica_key" "data" {
  provider                = aws.secondary
  description             = "${local.name} data encryption (replica)"
  primary_key_arn         = aws_kms_key.data.arn
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "data_secondary" {
  provider      = aws.secondary
  name          = "alias/${local.name}-data"
  target_key_id = aws_kms_replica_key.data.key_id
}