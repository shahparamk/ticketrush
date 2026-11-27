output "tables" {
  value = { for k, t in aws_dynamodb_table.this : k => t.name }
}

output "kms_key_arn_primary" {
  value = aws_kms_key.data.arn
}

output "kms_key_arn_secondary" {
  value = aws_kms_replica_key.data.arn
}

output "hello_url_primary" {
  value = module.hello_primary.url
}

output "hello_url_secondary" {
  value = module.hello_secondary.url
}