# ─────────────────────────────────────────────
# Production Environment
# Branch: main
#
# Blue-Green deployment strategy:
#   - Two ECS service sets (blue + green) can coexist
#   - New deployment goes to inactive slot
#   - After 24h health check, old slot is destroyed
#   - Manual destroy required (no auto-cleanup)
# ─────────────────────────────────────────────

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40.0" # Pinned for production stability — update deliberately after testing
    }
  }

  backend "s3" {
    # -backend-config="bucket=nexusdeploy-terraform-state"
    # -backend-config="key=prod/terraform.tfstate"
    # -backend-config="region=us-east-1"
    # -backend-config="encrypt=true"
    #
    # DynamoDB locking (recommended for prod team use - enable when needed):
    # dynamodb_table = "nexusdeploy-terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

locals {
  environment = "prod"
  project     = "nexusdeploy"

  # Blue-green: determine active slot from variable
  # deploy.yml sets this based on what's currently running
  active_slot   = var.deployment_slot # "blue" or "green"

  common_tags = {
    Project     = local.project
    Environment = local.environment
    ManagedBy   = "terraform"
    GitCommit   = var.git_commit
    Owner       = "devops-team"
    # No TTL tag in prod - manual destroy only
  }
}


# ══════════════════════════════════════════════
# SECRETS — All from SSM, zero hardcoding
# ══════════════════════════════════════════════

data "aws_ssm_parameter" "db_master_username" {
  name            = "/${local.project}/${local.environment}/db/master_username"
  with_decryption = false
}

data "aws_ssm_parameter" "db_master_password" {
  name            = "/${local.project}/${local.environment}/db/master_password"
  with_decryption = true
}

data "aws_ssm_parameter" "db_app_username" {
  name            = "/${local.project}/${local.environment}/db/app_username"
  with_decryption = false
}

data "aws_ssm_parameter" "db_app_password" {
  name            = "/${local.project}/${local.environment}/db/app_password"
  with_decryption = true
}

data "aws_ssm_parameter" "app_secret_key" {
  name            = "/${local.project}/${local.environment}/app/secret_key"
  with_decryption = true
}

data "aws_ssm_parameter" "jwt_secret_key" {
  name            = "/${local.project}/${local.environment}/app/jwt_secret_key"
  with_decryption = true
}

data "aws_ssm_parameter" "grafana_admin_password" {
  name            = "/${local.project}/${local.environment}/monitoring/grafana_password"
  with_decryption = true
}

# ── Secrets Manager ───────────────────────────
resource "aws_secretsmanager_secret" "app" {
  name                    = "${local.project}/${local.environment}/app-secrets"
  description             = "Runtime secrets injected by ECS at container launch"
  recovery_window_in_days = 7 # 7-day recovery window in prod (safety net)
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id

  secret_string = jsonencode({
    DATABASE_URL          = "postgresql://${data.aws_ssm_parameter.db_app_username.value}:${data.aws_ssm_parameter.db_app_password.value}@${module.rds.db_endpoint}/${var.db_name}"
    REDIS_URL             = "redis://${module.elasticache.redis_endpoint}:6379/0"
    CELERY_BROKER_URL     = "redis://${module.elasticache.redis_endpoint}:6379/0"
    CELERY_RESULT_BACKEND = "redis://${module.elasticache.redis_endpoint}:6379/0"
    SECRET_KEY            = data.aws_ssm_parameter.app_secret_key.value
    JWT_SECRET_KEY        = data.aws_ssm_parameter.jwt_secret_key.value
    AWS_REGION            = var.aws_region
    S3_BUCKET             = var.app_s3_bucket
  })
}

# ══════════════════════════════════════════════
# INFRASTRUCTURE MODULES
# ══════════════════════════════════════════════

module "iam" {
  source = "../../modules/iam"

  project               = local.project
  environment           = local.environment
  github_org           = var.github_org
  github_repo          = var.github_repo
  tf_state_bucket      = var.tf_state_bucket
  app_s3_bucket        = var.app_s3_bucket
  secrets_arn          = aws_secretsmanager_secret.app.arn
  create_oidc_provider = false # Already created by dev env - reuse it
  common_tags          = local.common_tags
}

module "vpc" {
  source = "../../modules/vpc"

  project               = local.project
  environment           = local.environment
  vpc_cidr              = var.vpc_cidr
  availability_zones    = var.availability_zones
  enable_nat_gateway    = false # Still off for cost; enable if workers need internet
  flow_log_role_arn     = module.iam.vpc_flow_log_role_arn
  flow_log_traffic_type = "ALL" # Full visibility in prod for compliance/security auditing
  log_retention_days    = 14 # Longer retention in prod
  common_tags           = local.common_tags
}

module "security_groups" {
  source = "../../modules/security-groups"

  project            = local.project
  environment        = local.environment
  vpc_id             = module.vpc.vpc_id
  vpc_cidr           = var.vpc_cidr
  monitoring_enabled = true
  common_tags        = local.common_tags
}

module "ecr" {
  source = "../../modules/ecr"

  project     = local.project
  environment = local.environment
  common_tags = local.common_tags
}

module "rds" {
  source = "../../modules/rds"

  project               = local.project
  environment           = local.environment
  private_db_subnet_ids = module.vpc.private_db_subnet_ids
  rds_sg_id             = module.security_groups.rds_sg_id
  db_name               = var.db_name
  db_master_username    = data.aws_ssm_parameter.db_master_username.value
  db_master_password    = data.aws_ssm_parameter.db_master_password.value
  db_instance_class     = "db.t3.micro"
  db_storage_gb         = 20
  common_tags           = local.common_tags
}

module "elasticache" {
  source = "../../modules/elasticache"

  project                  = local.project
  environment              = local.environment
  private_cache_subnet_ids = module.vpc.private_cache_subnet_ids
  redis_sg_id              = module.security_groups.redis_sg_id
  node_type                = "cache.t3.micro"
  common_tags              = local.common_tags
}

# ══════════════════════════════════════════════
# BLUE-GREEN ECS DEPLOYMENT
#
# How it works:
#   1. First deploy: slot = "blue", only blue ECS service runs
#   2. Next deploy:  slot = "green"
#      - Green service launches with new image (new tasks start)
#      - Both blue and green run simultaneously for 24 hours
#      - deploy.yml polls green health for 24h, then destroys blue
#   3. If green fails health checks → deploy.yml reverts slot to "blue"
#
# Terraform manages both slots. The inactive one has desired_count=0
# so it costs nothing while standing by.
# ══════════════════════════════════════════════

# ── Blue slot ─────────────────────────────────
module "ecs_blue" {
  source = "../../modules/ecs"

  project                = local.project
  environment            = "${local.environment}-blue" # Separate service names
  aws_region             = var.aws_region
  api_image              = local.active_slot == "blue" ? var.api_image : var.previous_api_image
  worker_image           = local.active_slot == "blue" ? var.worker_image : var.previous_worker_image
  git_commit             = var.git_commit
  private_app_subnet_ids = module.vpc.private_app_subnet_ids
  public_subnet_ids      = module.vpc.public_subnet_ids
  api_sg_id              = module.security_groups.api_sg_id
  worker_sg_id           = module.security_groups.worker_sg_id
  ecs_execution_role_arn = module.iam.ecs_execution_role_arn
  ecs_task_role_arn      = module.iam.ecs_task_role_arn
  secrets_arn            = aws_secretsmanager_secret.app.arn
  log_retention_days     = 14

  # Blue is active when deployment_slot = "blue", else it's being drained
  api_desired_count    = local.active_slot == "blue" ? 1 : 0
  worker_desired_count = local.active_slot == "blue" ? 1 : 0
  api_cpu              = 256
  api_memory           = 512
  worker_cpu           = 256
  worker_memory        = 512

  common_tags = merge(local.common_tags, { Slot = "blue" })
}

# ── Green slot ────────────────────────────────
module "ecs_green" {
  source = "../../modules/ecs"

  project                = local.project
  environment            = "${local.environment}-green"
  aws_region             = var.aws_region
  api_image              = local.active_slot == "green" ? var.api_image : var.previous_api_image
  worker_image           = local.active_slot == "green" ? var.worker_image : var.previous_worker_image
  git_commit             = var.git_commit
  private_app_subnet_ids = module.vpc.private_app_subnet_ids
  public_subnet_ids      = module.vpc.public_subnet_ids
  api_sg_id              = module.security_groups.api_sg_id
  worker_sg_id           = module.security_groups.worker_sg_id
  ecs_execution_role_arn = module.iam.ecs_execution_role_arn
  ecs_task_role_arn      = module.iam.ecs_task_role_arn
  secrets_arn            = aws_secretsmanager_secret.app.arn
  log_retention_days     = 14

  # Green is active when deployment_slot = "green"
  api_desired_count    = local.active_slot == "green" ? 1 : 0
  worker_desired_count = local.active_slot == "green" ? 1 : 0
  api_cpu              = 256
  api_memory           = 512
  worker_cpu           = 256
  worker_memory        = 512

  common_tags = merge(local.common_tags, { Slot = "green" })
}

# ── Monitoring ────────────────────────────────
module "monitoring" {
  source = "../../modules/monitoring"

  project                = local.project
  environment            = local.environment
  aws_region             = var.aws_region
  public_subnet_id       = module.vpc.public_subnet_ids[0]
  monitoring_sg_id       = module.security_groups.monitoring_sg_id
  ecs_cluster_name       = module.ecs_blue.cluster_name # Cluster is shared
  cloudwatch_log_groups  = [
    "/ecs/${local.project}/${local.environment}-blue/api",
    "/ecs/${local.project}/${local.environment}-green/api",
    "/ecs/${local.project}/${local.environment}-blue/worker",
    "/ecs/${local.project}/${local.environment}-green/worker",
  ]
  common_tags = local.common_tags
}

# ── SSM: Store active slot for next deployment ─
# deploy.yml reads this to know which slot is currently active
resource "aws_ssm_parameter" "active_slot" {
  name  = "/${local.project}/${local.environment}/deployment/active_slot"
  type  = "String"
  value = local.active_slot

  tags = local.common_tags

  lifecycle {
    ignore_changes = [value] # deploy.yml manages this value, not Terraform
  }
}
