variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment (dev, staging, prod)"
  type        = string
}

variable "create_oidc_provider" {
  description = "Whether to create GitHub OIDC provider"
  type        = bool
  default     = false
}

variable "oidc_provider_arn" {
  description = "ARN of existing GitHub OIDC provider (if create_oidc_provider = false)"
  type        = string
  default     = ""
}

variable "github_org" {
  description = "GitHub organization or username"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
}

variable "deploy_branches" {
  description = "GitHub branches allowed to deploy (OIDC assume role restriction)"
  type        = list(string)
  default     = ["main"]
  validation {
    condition     = length(var.deploy_branches) > 0
    error_message = "deploy_branches must contain at least one branch."
  }
}

variable "tf_state_bucket" {
  description = "S3 bucket for Terraform state"
  type        = string
}

variable "tf_lock_table" {
  description = "DynamoDB table for Terraform state locking"
  type        = string
}

variable "secrets_arn" {
  description = "ARN of Secrets Manager secret for app secrets"
  type        = string
}

variable "app_s3_bucket" {
  description = "S3 bucket for application file attachments"
  type        = string
}

variable "ecr_repository_names" {
  description = "List of ECR repository names for CI/CD to push images"
  type        = list(string)
  default     = ["api", "worker"]  # Will be formatted as ${project}-${repo_name}
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
}
