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
  default = "10.2.0.0/16" # dev=10.0, prod=10.1, staging=10.2
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

variable "keep_previous_slot_running" {
  description = "Keep the inactive slot at capacity so it serves traffic until the new slot is verified healthy (blue-green overlap). The deploy apply sets true; the reclaim apply sets false to scale the drained slot to 0."
  type        = bool
  default     = false
}

variable "beat_slot" {
  description = "Slot Celery Beat should run on. Empty (default) tracks deployment_slot — Beat cuts over in the same apply as API/worker, which is what a first-ever deploy (no previous slot to hold it back) wants. deploy-blue-green.yml sets this explicitly on a rotation deploy: it holds Beat on the OLD slot during the candidate-creation apply, then a second, narrow apply cuts it to the new slot only once promoted. See docs/design-decisions.md#celery-beat-is-a-singleton."
  type        = string
  default     = ""

  validation {
    condition     = contains(["", "slot1", "slot2"], var.beat_slot)
    error_message = "beat_slot must be \"\", \"slot1\", or \"slot2\"."
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

variable "alert_email" {
  description = "Email for CloudWatch alarm notifications via SNS. Blank creates the topic and wires the alarms but adds no subscription; set it (e.g. via TF_VAR_alert_email) to receive mail."
  type        = string
  default     = ""
}
