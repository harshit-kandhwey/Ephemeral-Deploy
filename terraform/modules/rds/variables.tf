variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment (dev, staging, prod)"
  type        = string
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_storage_gb" {
  description = "Initial RDS storage in GB"
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Initial database name"
  type        = string
}

variable "db_master_username" {
  description = "RDS master username"
  type        = string
  sensitive   = true
}

variable "db_master_password" {
  description = "RDS master password"
  type        = string
  sensitive   = true
}

variable "private_db_subnet_ids" {
  description = "Private subnet IDs for RDS"
  type        = list(string)
}

variable "rds_sg_id" {
  description = "Security group ID for RDS"
  type        = string
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
}

variable "final_snapshot_identifier" {
  description = "Final snapshot identifier for RDS (required for prod on destroy)"
  type        = string
  default     = null
}

variable "enable_performance_insights" {
  description = "Enable Performance Insights for RDS (prod by default)"
  type        = bool
  default     = null # null means auto-enable for prod only
}
