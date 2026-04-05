variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment (dev, staging, prod)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "availability_zones" {
  description = "List of availability zones to deploy into"
  type        = list(string)
}

variable "enable_nat_gateway" {
  description = "Whether to create a NAT Gateway for private subnet outbound access"
  type        = bool
  default     = false
}

variable "flow_log_role_arn" {
  description = "IAM role ARN for VPC Flow Logs to write to CloudWatch"
  type        = string
}

variable "flow_log_traffic_type" {
  description = "Traffic type to capture in VPC Flow Logs. REJECT is cost-optimised for dev (captures security events only). Use ALL in prod for full visibility and compliance."
  type        = string
  default     = "REJECT"

  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.flow_log_traffic_type)
    error_message = "flow_log_traffic_type must be one of: ACCEPT, REJECT, ALL."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 3
}

variable "common_tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
}

variable "aws_region" {
  description = "AWS region for VPC endpoint service names"
  type        = string
  default     = "us-east-1"
}
