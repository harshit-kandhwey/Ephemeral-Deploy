github_org         = "YOUR_GITHUB_USERNAME" # ← change this
github_repo        = "Ephemeral-Deploy"     # ← change to your repo name
tf_state_bucket    = "nexusdeploy-terraform-state"
app_s3_bucket      = "nexusdeploy-attachments-prod"
vpc_cidr           = "10.1.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b"]
db_name            = "nexusdeploy"