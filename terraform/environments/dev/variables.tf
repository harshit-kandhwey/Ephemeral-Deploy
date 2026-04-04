variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "git_commit" {
  description = "Git commit SHA — injected by CI"
  type        = string
  default     = "local"
}

variable "github_org" {
  description = "GitHub organisation or username"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
}

variable "tf_state_bucket" {
  description = "S3 bucket for Terraform state"
  type        = string
}

variable "app_s3_bucket" {
  description = "S3 bucket for application file attachments"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones to deploy into"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = "nexusdeploy"
}

variable "api_image" {
  description = "Docker image URI for the API — injected by CI"
  type        = string
  default     = "placeholder"
}

variable "worker_image" {
  description = "Docker image URI for the worker — injected by CI"
  type        = string
  default     = "placeholder"
}