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
