terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ─────────────────────────────────────────────
# ElastiCache Module - Redis (free-tier eligible)
# ─────────────────────────────────────────────

resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.project}-${var.environment}-cache-subnet"
  subnet_ids = var.private_cache_subnet_ids

  tags = var.common_tags
}

# A replication group, not a bare cache cluster, because in-transit
# encryption (transit_encryption_enabled) and an AUTH token are only
# exposed on aws_elasticache_replication_group — the AWS provider has no
# equivalent attribute on aws_elasticache_cluster at all. num_cache_clusters
# = 1 keeps this a single node (no HA/failover cost) — same topology and
# cost profile as the plain cluster this replaces, plus TLS + AUTH. See
# docs/design-decisions.md#elasticache-in-transit-encryption-and-auth.
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${var.project}-${var.environment}-redis"
  description          = "${var.project} ${var.environment} Redis (Celery broker/result backend, rate limiter, JWT blocklist)"
  engine               = "redis"
  engine_version       = "7.0"
  node_type            = var.node_type # cache.t3.micro is free-tier eligible
  num_cache_clusters   = 1
  parameter_group_name = "default.redis7"
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [var.redis_sg_id]

  transit_encryption_enabled = true
  # Only settable at creation (changing it later means recreating the group),
  # and free with the default AWS-managed key — so this migration is the one
  # cheap moment to turn it on. Covers prod's retained snapshots, which can
  # hold Celery payloads/results. See
  # docs/design-decisions.md#elasticache-in-transit-encryption-and-auth.
  at_rest_encryption_enabled = true
  auth_token                 = var.redis_auth_token

  automatic_failover_enabled = false # single node — nothing to fail over to

  # Backup - off in dev to save costs
  snapshot_retention_limit = var.environment == "prod" ? 1 : 0

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-redis"
  })
}
