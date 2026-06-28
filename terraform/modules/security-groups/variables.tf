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

variable "monitoring_allowed_cidr" {
  description = "CIDR blocks allowed to reach Prometheus (9090) and Grafana (3000). Must be set explicitly — no default to prevent accidental public exposure."
  type        = list(string)
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
}
