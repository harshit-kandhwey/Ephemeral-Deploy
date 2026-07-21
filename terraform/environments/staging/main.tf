# ─────────────────────────────────────────────
# Staging Environment — mirrors prod exactly
# Branch: staging
#
# Purpose: validate prod deployment patterns before
# promoting changes to main. Same blue-green strategy,
# same provider pin, same secrets flow as prod.
#
# Manual destroy required — no auto-cleanup TTL.
# ─────────────────────────────────────────────

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40.0" # Pinned — same as prod for parity
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    # -backend-config="bucket=nexusdeploy-terraform-state"
    # -backend-config="key=staging/terraform.tfstate"
    # -backend-config="region=us-east-1"
    # -backend-config="encrypt=true"
    # -backend-config="dynamodb_table=nexusdeploy-terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

locals {
  environment = "staging"
  project     = "nexusdeploy"

  active_slot = var.deployment_slot # "slot1" or "slot2"

  # Capacity for the NON-active slot. Blue-green needs the previous slot to keep
  # serving until the new slot is verified healthy, otherwise a single apply
  # scales the old slot to 0 while the new one is still inside its startPeriod —
  # an outage window with no slot serving. The deploy apply passes true (overlap);
  # the reclaim apply (cleanup.yml, after the drain delay) passes false to
  # actually scale the drained slot down.
  #
  # API and worker only. Beat is a SINGLETON — two Beat containers fire every
  # scheduled task twice, and the overlap window is 2h (staging) / 24h (prod),
  # so beat_desired_count stays tied to the active slot alone.
  inactive_slot_count = var.keep_previous_slot_running ? 1 : 0

  common_tags = {
    Project     = local.project
    Environment = local.environment
    ManagedBy   = "terraform"
    GitCommit   = var.git_commit
    Owner       = "devops-team"
  }
}

# ══════════════════════════════════════════════
# SECRETS — SSM → Secrets Manager → ECS injection
# Same flow as prod. Bootstrap must be run for staging
# before first deploy: ./scripts/bootstrap.sh --env staging
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


resource "aws_secretsmanager_secret" "app" {
  name                    = "${local.project}/${local.environment}/app-secrets"
  description             = "Runtime secrets injected by ECS at container launch"
  recovery_window_in_days = 0 # Instant deletion — staging is ephemeral (torn down like dev); a 7-day hold traps the name and blocks re-apply
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id

  secret_string = jsonencode({
    DATABASE_URL          = "postgresql://${data.aws_ssm_parameter.db_app_username.value}:${data.aws_ssm_parameter.db_app_password.value}@${module.rds.db_endpoint}/${var.db_name}?sslmode=require"
    REDIS_URL             = "redis://${module.elasticache.redis_endpoint}:6379/0"
    CELERY_BROKER_URL     = "redis://${module.elasticache.redis_endpoint}:6379/0"
    CELERY_RESULT_BACKEND = "redis://${module.elasticache.redis_endpoint}:6379/0"
    SECRET_KEY            = data.aws_ssm_parameter.app_secret_key.value
    JWT_SECRET_KEY        = data.aws_ssm_parameter.jwt_secret_key.value
    AWS_REGION            = var.aws_region
    S3_BUCKET             = var.app_s3_bucket
    DB_APP_USER           = data.aws_ssm_parameter.db_app_username.value
    DB_APP_PASSWORD       = data.aws_ssm_parameter.db_app_password.value
  })
}

resource "aws_secretsmanager_secret" "init" {
  name                    = "${local.project}/${local.environment}/init-secrets"
  description             = "DB master credentials for worker DB initialisation only"
  recovery_window_in_days = 0 # Instant deletion — staging is ephemeral (torn down like dev)
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "init" {
  secret_id = aws_secretsmanager_secret.init.id

  secret_string = jsonencode({
    DB_MASTER_USER     = data.aws_ssm_parameter.db_master_username.value
    DB_MASTER_PASSWORD = data.aws_ssm_parameter.db_master_password.value
  })
}

# ── Seed user passwords ───────────────────────────────────────
# Strong, unique-per-environment passwords for the demo seed users, injected
# into the worker init task via a SEPARATE secret from the DB master credentials
# so a demo login can be delegated without exposing DB_MASTER_PASSWORD
# (GetSecretValue cannot be scoped to a single JSON key). Replaces the hard-coded
# "ChangeMe-*" fallbacks in init_db.py (visible in the public repo). Retrieve
# them from Secrets Manager (seed-secrets) to sign in as a seed user.
resource "random_password" "seed_admin" {
  length           = 24
  special          = true
  override_special = "!#$%^&*()-_=+"
}

resource "random_password" "seed_manager" {
  length           = 24
  special          = true
  override_special = "!#$%^&*()-_=+"
}

resource "random_password" "seed_dev" {
  length           = 24
  special          = true
  override_special = "!#$%^&*()-_=+"
}

resource "aws_secretsmanager_secret" "seed" {
  name                    = "${local.project}/${local.environment}/seed-secrets"
  description             = "Demo seed-user login passwords (no DB master credential)"
  recovery_window_in_days = 0 # Instant deletion — staging is ephemeral (torn down like dev)
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "seed" {
  secret_id = aws_secretsmanager_secret.seed.id

  secret_string = jsonencode({
    SEED_ADMIN_PASSWORD   = random_password.seed_admin.result
    SEED_MANAGER_PASSWORD = random_password.seed_manager.result
    SEED_DEV_PASSWORD     = random_password.seed_dev.result
  })
}

# ══════════════════════════════════════════════
# INFRASTRUCTURE MODULES
# ══════════════════════════════════════════════

module "iam" {
  source = "../../modules/iam"

  project              = local.project
  environment          = local.environment
  github_org           = var.github_org
  github_repo          = var.github_repo
  tf_state_bucket      = var.tf_state_bucket
  app_s3_bucket        = var.app_s3_bucket
  secrets_arn          = aws_secretsmanager_secret.app.arn
  init_secrets_arn     = aws_secretsmanager_secret.init.arn
  seed_secrets_arn     = aws_secretsmanager_secret.seed.arn
  create_oidc_provider = false # Shared with dev/prod — created once by bootstrap
  common_tags          = local.common_tags
}

module "vpc" {
  source = "../../modules/vpc"

  project               = local.project
  environment           = local.environment
  vpc_cidr              = var.vpc_cidr
  availability_zones    = var.availability_zones
  enable_nat_gateway    = false
  flow_log_role_arn     = module.iam.vpc_flow_log_role_arn
  flow_log_traffic_type = "ALL" # Full visibility — matches prod
  log_retention_days    = 14
  common_tags           = local.common_tags
}

module "security_groups" {
  source = "../../modules/security-groups"

  project                 = local.project
  environment             = local.environment
  vpc_id                  = module.vpc.vpc_id
  vpc_cidr                = var.vpc_cidr
  monitoring_enabled      = true
  monitoring_allowed_cidr = var.monitoring_allowed_cidr
  common_tags             = local.common_tags
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
# BLUE-GREEN ECS DEPLOYMENT — same as prod
# ══════════════════════════════════════════════

module "ecs_slot1" {
  source = "../../modules/ecs"

  project                       = local.project
  environment                   = "${local.environment}-slot1"
  aws_region                    = var.aws_region
  api_image                     = local.active_slot == "slot1" ? var.api_image : var.previous_api_image
  worker_image                  = local.active_slot == "slot1" ? var.worker_image : var.previous_worker_image
  git_commit                    = var.git_commit
  private_app_subnet_ids        = module.vpc.private_app_subnet_ids
  api_sg_id                     = module.security_groups.api_sg_id
  worker_sg_id                  = module.security_groups.worker_sg_id
  ecs_execution_role_arn        = module.iam.ecs_execution_role_arn
  ecs_execution_worker_role_arn = module.iam.ecs_execution_worker_role_arn
  ecs_task_role_arn             = module.iam.ecs_task_role_arn
  secrets_arn                   = aws_secretsmanager_secret.app.arn
  init_secrets_arn              = aws_secretsmanager_secret.init.arn
  seed_secrets_arn              = aws_secretsmanager_secret.seed.arn
  log_retention_days            = 14

  api_desired_count    = local.active_slot == "slot1" ? 1 : local.inactive_slot_count
  worker_desired_count = local.active_slot == "slot1" ? 1 : local.inactive_slot_count
  beat_desired_count   = local.active_slot == "slot1" ? 1 : 0
  api_cpu              = 256
  api_memory           = 512
  worker_cpu           = 256
  worker_memory        = 512

  common_tags = merge(local.common_tags, { Slot = "slot1" })

  depends_on = [
    aws_secretsmanager_secret_version.app,
    aws_secretsmanager_secret_version.init,
    module.rds,
    module.elasticache,
  ]
}

module "ecs_slot2" {
  source = "../../modules/ecs"

  project                       = local.project
  environment                   = "${local.environment}-slot2"
  aws_region                    = var.aws_region
  api_image                     = local.active_slot == "slot2" ? var.api_image : var.previous_api_image
  worker_image                  = local.active_slot == "slot2" ? var.worker_image : var.previous_worker_image
  git_commit                    = var.git_commit
  private_app_subnet_ids        = module.vpc.private_app_subnet_ids
  api_sg_id                     = module.security_groups.api_sg_id
  worker_sg_id                  = module.security_groups.worker_sg_id
  ecs_execution_role_arn        = module.iam.ecs_execution_role_arn
  ecs_execution_worker_role_arn = module.iam.ecs_execution_worker_role_arn
  ecs_task_role_arn             = module.iam.ecs_task_role_arn
  secrets_arn                   = aws_secretsmanager_secret.app.arn
  init_secrets_arn              = aws_secretsmanager_secret.init.arn
  seed_secrets_arn              = aws_secretsmanager_secret.seed.arn
  log_retention_days            = 14

  api_desired_count    = local.active_slot == "slot2" ? 1 : local.inactive_slot_count
  worker_desired_count = local.active_slot == "slot2" ? 1 : local.inactive_slot_count
  beat_desired_count   = local.active_slot == "slot2" ? 1 : 0
  api_cpu              = 256
  api_memory           = 512
  worker_cpu           = 256
  worker_memory        = 512

  common_tags = merge(local.common_tags, { Slot = "slot2" })

  depends_on = [
    aws_secretsmanager_secret_version.app,
    aws_secretsmanager_secret_version.init,
    module.rds,
    module.elasticache,
  ]
}

module "monitoring" {
  source = "../../modules/monitoring"

  project          = local.project
  environment      = local.environment
  aws_region       = var.aws_region
  public_subnet_id = module.vpc.public_subnet_ids[0]
  monitoring_sg_id = module.security_groups.monitoring_sg_id
  # Constructed names, not module outputs: monitoring watches BOTH slot
  # clusters (the active one alternates) and provisions in parallel with ECS
  # instead of waiting on it — the discovery cron tolerates missing clusters.
  ecs_cluster_names = [
    "${local.project}-${local.environment}-slot1",
    "${local.project}-${local.environment}-slot2",
  ]
  state_bucket = var.tf_state_bucket
  common_tags  = local.common_tags
  alert_email  = var.alert_email
}

# NOTE: the /deployment/active_slot SSM parameter is intentionally NOT a
# Terraform resource. deploy-blue-green.yml creates and updates it (alongside
# the workflow-owned generation / prev_*_image parameters), and cleanup.yml
# deletes all four on teardown. Keeping it out of state avoids the split
# ownership that used to orphan the other three on `terraform destroy`.

# ── Outputs ───────────────────────────────────────────────────────────────────
output "app_secret_arn" {
  value = aws_secretsmanager_secret.app.arn
}

output "db_endpoint" {
  value = module.rds.db_endpoint
}

output "ecs_cluster_name_slot1" {
  value = module.ecs_slot1.cluster_name
}

output "ecs_cluster_name_slot2" {
  value = module.ecs_slot2.cluster_name
}

output "worker_sg_id" {
  value = module.security_groups.worker_sg_id
}

output "private_app_subnet_ids" {
  value = module.vpc.private_app_subnet_ids
}

output "grafana_url" {
  value = try("http://${module.monitoring.monitoring_public_ip}:3000", "")
}

output "prometheus_url" {
  value = try("http://${module.monitoring.monitoring_public_ip}:9090", "")
}
