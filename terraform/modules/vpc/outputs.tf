output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (one per AZ)"
  value       = aws_subnet.public[*].id
}

output "private_app_subnet_ids" {
  description = "Private app-tier subnet IDs for ECS tasks (one per AZ)"
  value       = aws_subnet.private_app[*].id
}

output "private_db_subnet_ids" {
  description = "Private database-tier subnet IDs for RDS (one per AZ)"
  value       = aws_subnet.private_db[*].id
}

output "private_cache_subnet_ids" {
  description = "Private cache-tier subnet IDs for ElastiCache (one per AZ)"
  value       = aws_subnet.private_cache[*].id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.main.cidr_block
}
