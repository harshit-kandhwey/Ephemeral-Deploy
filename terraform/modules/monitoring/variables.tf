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

variable "public_subnet_id" {
  description = "Public subnet ID to place the monitoring EC2 instance in"
  type        = string
}

variable "monitoring_sg_id" {
  description = "Security group ID for the monitoring EC2 instance"
  type        = string
}

variable "ecs_cluster_names" {
  description = "ECS cluster names for Prometheus service discovery and alarms — one per blue-green slot (single-element list for dev). API services and task families are named \"<cluster>-api\"."
  type        = list(string)
}

variable "state_bucket" {
  description = "S3 bucket name used for Terraform state — monitoring configs are stored here under monitoring/config/<env>/"
  type        = string
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
}
