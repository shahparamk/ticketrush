# All tables are Global Tables: written in us-east-1, replicated to us-west-2 (usually within ~1 s).
# On-demand billing: pay per request, so an idle table costs almost nothing.

locals {
  tables = {
    # One row per concert or event
    events = {
      hash_key  = "eventId"
      range_key = null
      ttl       = null
    }
    # One row per seat: status available / held / sold. Conditional writes on this table stop overselling.
    seats = {
      hash_key  = "eventId"
      range_key = "seatId"
      ttl       = null
    }
    # One row per completed or failed order
    orders = {
      hash_key  = "orderId"
      range_key = null
      ttl       = null
    }
    # Remembers each request's idempotency key, so a retried "Pay" click isn't processed twice.
    # Rows delete themselves after 24 h (TTL).
    idempotency = {
      hash_key  = "idempotencyKey"
      range_key = null
      ttl       = "expiresAt"
    }
  }
}

resource "aws_dynamodb_table" "this" {
  for_each = local.tables

  name         = "${local.name}-${each.key}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = each.value.hash_key
  range_key    = each.value.range_key

  # Global Tables need a stream of every change; it's also what drives the live seat map later
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  attribute {
    name = each.value.hash_key
    type = "S"
  }

  dynamic "attribute" {
    for_each = each.value.range_key == null ? [] : [each.value.range_key]
    content {
      name = attribute.value
      type = "S"
    }
  }

  dynamic "ttl" {
    for_each = each.value.ttl == null ? [] : [each.value.ttl]
    content {
      attribute_name = ttl.value
      enabled        = true
    }
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.data.arn
  }

  point_in_time_recovery {
    enabled = true # restore to any second in the last 35 days
  }

  replica {
    region_name            = "us-west-2"
    kms_key_arn            = aws_kms_replica_key.data.arn
    point_in_time_recovery = true
    propagate_tags         = true
  }
}