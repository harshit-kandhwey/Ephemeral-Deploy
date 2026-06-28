github_org         = "harshit-kandhwey"
github_repo        = "Ephemeral-Deploy"
tf_state_bucket    = "nexusdeploy-terraform-state"
app_s3_bucket      = "nexusdeploy-attachments-prod"
vpc_cidr           = "10.1.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b"]
db_name                 = "nexusdeploy"
monitoring_allowed_cidr = ["0.0.0.0/0"] # TODO: restrict to your IP or VPN CIDR in production
