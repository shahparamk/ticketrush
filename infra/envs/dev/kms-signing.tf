# The buyer-token signing key: ECDSA P-256 (ES256), multi-Region.
# The SAME key material exists in both regions, so a token issued in us-east-1 verifies in us-west-2.
# The private key never leaves KMS: Lambdas can only ask KMS to sign, or read the public key.

data "aws_iam_policy_document" "signing_key" {
  #checkov:skip=CKV_AWS_111:Key policy, not an IAM policy: "Resource: *" means this key only (AWS default key policy)
  #checkov:skip=CKV_AWS_356:Key policy, not an IAM policy: "Resource: *" means this key only (AWS default key policy)
  #checkov:skip=CKV_AWS_109:Key policy, not an IAM policy: delegates key access to IAM, the AWS default
  statement {
    sid       = "EnableIAMPolicies"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "signing" {
  #checkov:skip=CKV_AWS_7:KMS can't auto-rotate asymmetric keys; rotation means a new key and a new "kid" in the token header
  description              = "${local.name} buyer-token signing (ES256)"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_NIST_P256"
  multi_region             = true
  deletion_window_in_days  = 7
  policy                   = data.aws_iam_policy_document.signing_key.json
}

resource "aws_kms_alias" "signing" {
  name          = "alias/${local.name}-signing"
  target_key_id = aws_kms_key.signing.key_id
}

resource "aws_kms_replica_key" "signing" {
  provider                = aws.secondary
  description             = "${local.name} buyer-token signing (replica)"
  primary_key_arn         = aws_kms_key.signing.arn
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.signing_key.json
}

resource "aws_kms_alias" "signing_secondary" {
  provider      = aws.secondary
  name          = "alias/${local.name}-signing"
  target_key_id = aws_kms_replica_key.signing.key_id
}