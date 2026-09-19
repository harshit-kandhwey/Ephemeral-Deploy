output "redis_endpoint" {
  description = "Redis primary endpoint address"
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "redis_port" {
  description = "Redis port"
  value       = aws_elasticache_replication_group.redis.port
}

output "cluster_id" {
  description = "ElastiCache replication group ID"
  value       = aws_elasticache_replication_group.redis.replication_group_id
}
