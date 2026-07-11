variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "git_commit" {
  type    = string
  default = "local"
}

variable "github_org" {
  type = string
}

variable "github_repo" {
  type = string
}

variable "tf_state_bucket" {
  type = string
}

variable "app_s3_bucket" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "availability_zones" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "db_name" {
  type    = string
  default = "nexusdeploy"
}

variable "api_image" {
  type    = string
  default = "placeholder"
}

variable "worker_image" {
  type    = string
  default = "placeholder"
}

variable "deployment_slot" {
  description = "Active deployment slot: slot1 or slot2"
  type        = string
  default     = "slot1"

  # An invalid value (e.g. a leftover legacy "blue") would silently set BOTH
  # slots to desired_count=0 and select previous_*_image — fail fast instead.
  validation {
    condition     = contains(["slot1", "slot2"], var.deployment_slot)
    error_message = "deployment_slot must be either \"slot1\" or \"slot2\"."
  }
}

variable "previous_api_image" {
  description = "Previous API image — kept on the inactive slot"
  type        = string
  default     = "placeholder"
}

variable "previous_worker_image" {
  description = "Previous worker image — kept on the inactive slot"
  type        = string
  default     = "placeholder"
}

variable "monitoring_allowed_cidr" {
  description = "CIDR blocks allowed inbound to Prometheus (9090) and Grafana (3000). Set to your IP or VPN range."
  type        = list(string)
}
