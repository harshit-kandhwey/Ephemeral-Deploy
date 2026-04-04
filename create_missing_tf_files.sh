#!/bin/bash
# Run from your repo root: bash create_missing_tf_files.sh
set -euo pipefail
echo "Creating missing Terraform module files..."

# ── security-groups ──────────────────────────────────────────────────────────
mkdir -p terraform/modules/security-groups

cat > terraform/modules/security-groups/variables.tf << 'EOF'
variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment (dev, staging, prod)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to create security groups in"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block used to scope ingress/egress rules"
  type        = string
}

variable "monitoring_enabled" {
  description = "Whether to create the monitoring security group"
  type        = bool
  default     = false
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
}
EOF

cat > terraform/modules/security-groups/outputs.tf << 'EOF'
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
EOF

# ── ecs ──────────────────────────────────────────────────────────────────────
mkdir -p terraform/modules/ecs

cat > terraform/modules/ecs/variables.tf << 'EOF'
variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment (dev, staging, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region for CloudWatch log groups"
  type        = string
}

variable "api_image" {
  description = "Docker image URI for the API container"
  type        = string
}

variable "worker_image" {
  description = "Docker image URI for the Celery worker container"
  type        = string
}

variable "git_commit" {
  description = "Git commit SHA injected as VERSION env var into containers"
  type        = string
  default     = "unknown"
}

variable "vpc_id" {
  description = "VPC ID (used for ALB when enabled)"
  type        = string
}

variable "private_app_subnet_ids" {
  description = "Private subnet IDs for ECS task network placement"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs (used for ALB when enabled)"
  type        = list(string)
}

variable "api_sg_id" {
  description = "Security group ID for API tasks"
  type        = string
}

variable "worker_sg_id" {
  description = "Security group ID for worker and beat tasks"
  type        = string
}

variable "ecs_execution_role_arn" {
  description = "IAM role ARN for ECS task execution (ECR pull + CloudWatch logs)"
  type        = string
}

variable "ecs_task_role_arn" {
  description = "IAM role ARN for the running application (S3, etc.)"
  type        = string
}

variable "secrets_arn" {
  description = "Secrets Manager secret ARN injected into containers at launch"
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch log group retention in days"
  type        = number
  default     = 3
}

variable "api_cpu" {
  description = "CPU units for the API Fargate task (1024 = 1 vCPU)"
  type        = number
  default     = 256
}

variable "api_memory" {
  description = "Memory in MB for the API Fargate task"
  type        = number
  default     = 512
}

variable "worker_cpu" {
  description = "CPU units for the worker Fargate task"
  type        = number
  default     = 256
}

variable "worker_memory" {
  description = "Memory in MB for the worker Fargate task"
  type        = number
  default     = 512
}

variable "api_desired_count" {
  description = "Desired number of running API tasks"
  type        = number
  default     = 1
}

variable "worker_desired_count" {
  description = "Desired number of running worker tasks"
  type        = number
  default     = 1
}

variable "api_max_count" {
  description = "Maximum number of API tasks for auto-scaling"
  type        = number
  default     = 4
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
}
EOF

cat > terraform/modules/ecs/outputs.tf << 'EOF'
output "cluster_name" {
  description = "ECS cluster name — used by monitoring module for Prometheus service discovery"
  value       = aws_ecs_cluster.main.name
}

output "cluster_id" {
  description = "ECS cluster ARN"
  value       = aws_ecs_cluster.main.id
}

output "api_service_name" {
  description = "ECS API service name"
  value       = aws_ecs_service.api.name
}

output "worker_service_name" {
  description = "ECS worker service name"
  value       = aws_ecs_service.worker.name
}
EOF

# ── elasticache ──────────────────────────────────────────────────────────────
mkdir -p terraform/modules/elasticache

cat > terraform/modules/elasticache/variables.tf << 'EOF'
variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment (dev, staging, prod)"
  type        = string
}

variable "private_cache_subnet_ids" {
  description = "Private subnet IDs for the ElastiCache subnet group"
  type        = list(string)
}

variable "redis_sg_id" {
  description = "Security group ID for the Redis cluster"
  type        = string
}

variable "node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t3.micro"
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
}
EOF

cat > terraform/modules/elasticache/outputs.tf << 'EOF'
output "redis_endpoint" {
  description = "Redis cluster endpoint address"
  value       = aws_elasticache_cluster.redis.cache_nodes[0].address
}

output "redis_port" {
  description = "Redis cluster port"
  value       = aws_elasticache_cluster.redis.port
}

output "cluster_id" {
  description = "ElastiCache cluster ID"
  value       = aws_elasticache_cluster.redis.cluster_id
}
EOF

# ── monitoring ───────────────────────────────────────────────────────────────
mkdir -p terraform/modules/monitoring

cat > terraform/modules/monitoring/variables.tf << 'EOF'
variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment (dev, staging, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the monitoring EC2 instance"
  type        = string
}

variable "public_subnet_id" {
  description = "Public subnet ID to place the monitoring EC2 instance in"
  type        = string
}

variable "monitoring_sg_id" {
  description = "Security group ID for the monitoring EC2 instance"
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS cluster name for Prometheus service discovery"
  type        = string
}

variable "grafana_admin_password" {
  description = "Grafana admin UI password"
  type        = string
  sensitive   = true
}

variable "cloudwatch_log_groups" {
  description = "List of CloudWatch log group names to surface in Grafana"
  type        = list(string)
  default     = []
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
}
EOF

cat > terraform/modules/monitoring/outputs.tf << 'EOF'
output "grafana_url" {
  description = "Grafana dashboard URL"
  value       = "http://${aws_eip.monitoring.public_ip}:3000"
}

output "prometheus_url" {
  description = "Prometheus UI URL"
  value       = "http://${aws_eip.monitoring.public_ip}:9090"
}

output "monitoring_instance_id" {
  description = "EC2 instance ID for the monitoring server"
  value       = aws_instance.monitoring.id
}

output "monitoring_public_ip" {
  description = "Elastic IP address of the monitoring server"
  value       = aws_eip.monitoring.public_ip
}
EOF

# ── iam ──────────────────────────────────────────────────────────────────────
mkdir -p terraform/modules/iam

cat > terraform/modules/iam/outputs.tf << 'EOF'
output "ecs_execution_role_arn" {
  description = "IAM role ARN for ECS task execution (ECR pull + CloudWatch logs)"
  value       = aws_iam_role.ecs_execution.arn
}

output "ecs_task_role_arn" {
  description = "IAM role ARN for the running application (S3, Secrets Manager, etc.)"
  value       = aws_iam_role.ecs_task.arn
}

output "vpc_flow_log_role_arn" {
  description = "IAM role ARN for VPC Flow Logs to write to CloudWatch"
  value       = aws_iam_role.vpc_flow_log.arn
}

output "github_actions_deploy_role_arn" {
  description = "IAM role ARN assumed by GitHub Actions via OIDC"
  value       = aws_iam_role.github_actions_deploy.arn
}
EOF

# ── vpc ──────────────────────────────────────────────────────────────────────
mkdir -p terraform/modules/vpc

cat > terraform/modules/vpc/outputs.tf << 'EOF'
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
EOF

# ── rds ──────────────────────────────────────────────────────────────────────
mkdir -p terraform/modules/rds

cat > terraform/modules/rds/outputs.tf << 'EOF'
output "db_endpoint" {
  description = "RDS instance endpoint (host:port) used to build DATABASE_URL"
  value       = aws_db_instance.main.endpoint
}

output "db_address" {
  description = "RDS instance hostname"
  value       = aws_db_instance.main.address
}

output "db_port" {
  description = "RDS instance port"
  value       = aws_db_instance.main.port
}

output "db_name" {
  description = "Database name"
  value       = aws_db_instance.main.db_name
}
EOF

# ── ecr ──────────────────────────────────────────────────────────────────────
mkdir -p terraform/modules/ecr

cat > terraform/modules/ecr/variables.tf << 'EOF'
variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment (dev, staging, prod)"
  type        = string
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
}
EOF

cat > terraform/modules/ecr/outputs.tf << 'EOF'
output "api_repository_url" {
  description = "ECR repository URL for the API image"
  value       = aws_ecr_repository.api.repository_url
}

output "worker_repository_url" {
  description = "ECR repository URL for the worker image"
  value       = aws_ecr_repository.worker.repository_url
}

output "api_repository_arn" {
  description = "ECR repository ARN for the API image"
  value       = aws_ecr_repository.api.arn
}

output "worker_repository_arn" {
  description = "ECR repository ARN for the worker image"
  value       = aws_ecr_repository.worker.arn
}
EOF

echo ""
echo "✅ Done. Files created:"
find terraform/modules -name 'variables.tf' -o -name 'outputs.tf' | sort

echo ""
echo "Next steps:"
echo "  git add terraform/modules/"
echo "  git commit -m 'fix: add missing module variables.tf and outputs.tf'"
echo "  git push"
