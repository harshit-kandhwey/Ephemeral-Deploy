# ─────────────────────────────────────────────
# ElastiCache Module - Redis (free-tier eligible)
# ─────────────────────────────────────────────

resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.project}-${var.environment}-cache-subnet"
  subnet_ids = var.private_cache_subnet_ids

  tags = var.common_tags
}


resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "${var.project}-${var.environment}-redis"
  engine               = "redis"
  engine_version       = "7.0"
  node_type            = var.node_type   # cache.t3.micro is free-tier eligible
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [var.redis_sg_id]

  # Backup - off in dev to save costs
  snapshot_retention_limit = var.environment == "prod" ? 1 : 0

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-redis"
  })
}
