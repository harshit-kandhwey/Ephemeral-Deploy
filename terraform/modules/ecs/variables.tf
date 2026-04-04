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
  description = "Git commit SHA — injected as VERSION env var into containers"
  type        = string
  default     = "unknown"
}


variable "private_app_subnet_ids" {
  description = "Private subnet IDs for ECS task network placement"
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
