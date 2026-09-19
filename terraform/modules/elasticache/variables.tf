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

variable "redis_auth_token" {
  description = "AUTH token for the Redis replication group (enables encrypted, authenticated connections — required by AWS whenever transit_encryption_enabled is true). Generated via random_password at the environment level, same pattern as the SEED_*_PASSWORD values. Must be 16-128 chars and may not contain '/', '\"', '@', or whitespace (AWS-enforced), the same override_special set already used for SEED_*_PASSWORD avoids all of them."
  type        = string
  sensitive   = true
}
