output "api_sg_id" {
  description = "Security group ID for ECS API tasks"
  value       = aws_security_group.api.id
}

output "worker_sg_id" {
  description = "Security group ID for Celery worker tasks"
  value       = aws_security_group.worker.id
}

output "rds_sg_id" {
  description = "Security group ID for RDS PostgreSQL"
  value       = aws_security_group.rds.id
}

output "redis_sg_id" {
  description = "Security group ID for ElastiCache Redis"
  value       = aws_security_group.redis.id
}

output "monitoring_sg_id" {
  description = "Security group ID for the monitoring EC2 instance"
  value       = var.monitoring_enabled ? aws_security_group.monitoring[0].id : null
}
