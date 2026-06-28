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
  description = "CIDR blocks allowed to reach Prometheus (9090) and Grafana (3000). Restrict to your IP/VPN range in production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
}
