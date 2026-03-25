# ─────────────────────────────────────────────
# Dev Environment - Cost-optimized, short-lived
# Branch: dev → auto-destroys after 30 minutes
# ─────────────────────────────────────────────

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # ── Remote State Backend ──────────────────
  # State stored in S3 per environment.
  # Bucket/key/region passed via -backend-config flags in CI/CD (deploy.yml).
  #
  # NOTE ON STATE LOCKING (DynamoDB):
  # We are intentionally NOT using DynamoDB state locking here.
  # Reason: Only one environment runs at a time (single-developer workflow),
  # so concurrent state conflicts are not a risk for this project.
  #
  # In a real team setup, you WOULD enable it to prevent two pipeline runs
  # from corrupting state simultaneously. It's ready to enable:
  #   Step 1: Uncomment table creation in scripts/bootstrap.sh
  #   Step 2: Add this to the backend block below:
  #           dynamodb_table = "nexusdeploy-terraform-locks"
  #   Cost:   Free (DynamoDB PAY_PER_REQUEST with <25 lock ops/day = $0.00)
  backend "s3" {
    # All values passed via -backend-config in deploy.yml:
    # bucket  = "nexusdeploy-terraform-state"
    # key     = "dev/terraform.tfstate"
    # region  = "us-east-1"
    # encrypt = true
    #
    # To enable locking, add:
    # dynamodb_table = "nexusdeploy-terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region

  # All resources automatically get these tags via provider default_tags.
  # This is critical - the cleanup script uses these tags to find and
  # delete every resource if terraform destroy fails.
  default_tags {
    tags = local.common_tags
  }
}

# ── Locals ────────────────────────────────────
locals {
  environment = "dev"
  project     = "nexusdeploy"

  common_tags = {
    Project     = local.project
    Environment = local.environment
    ManagedBy   = "terraform"
    GitCommit   = var.git_commit
    Owner       = "devops-team"
    TTL         = "30m"
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ══════════════════════════════════════════════
# SECRETS — Zero hardcoded values
#
# All credentials follow this flow:
#   1. bootstrap.sh creates SSM SecureString parameters (run once manually)
#   2. Terraform reads them via data sources (never stored in .tf or .tfvars)
#   3. Terraform builds Secrets Manager secret from SSM values
#   4. ECS injects Secrets Manager values as env vars at container launch
#   5. App code reads standard env vars — has no knowledge of AWS
#
# DB has two users:
#   master_user  → RDS superuser (only used by Terraform / init scripts)
#   app_user     → Limited-privilege user the Flask app connects as
#                  Created by the db-init ECS task on first boot
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

# ── Secrets Manager (ECS runtime injection) ──
resource "aws_secretsmanager_secret" "app" {
  name                    = "${local.project}/${local.environment}/app-secrets"
  description             = "Runtime secrets injected by ECS at container launch"
  recovery_window_in_days = 0   # Instant deletion in dev (no 30-day hold)
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id

  # All values sourced from SSM - zero hardcoding
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

  project              = local.project
  environment          = local.environment
  github_org           = var.github_org
  github_repo          = var.github_repo
  tf_state_bucket      = var.tf_state_bucket
  secrets_arn          = aws_secretsmanager_secret.app.arn
  app_s3_bucket        = var.app_s3_bucket
  create_oidc_provider = true
  common_tags          = local.common_tags
}

module "vpc" {
  source = "../../modules/vpc"

  project               = local.project
  environment           = local.environment
  vpc_cidr              = var.vpc_cidr
  availability_zones    = var.availability_zones
  enable_nat_gateway    = false   # Saves ~$1/day in dev
  flow_log_role_arn     = module.iam.vpc_flow_log_role_arn
  flow_log_traffic_type = "REJECT"  # Cost-optimised: capture security events only
  log_retention_days    = 3
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

module "ecs" {
  source = "../../modules/ecs"

  project                = local.project
  environment            = local.environment
  aws_region             = var.aws_region
  api_image              = var.api_image
  worker_image           = var.worker_image
  git_commit             = var.git_commit
  vpc_id                 = module.vpc.vpc_id
  private_app_subnet_ids = module.vpc.private_app_subnet_ids
  public_subnet_ids      = module.vpc.public_subnet_ids
  api_sg_id              = module.security_groups.api_sg_id
  worker_sg_id           = module.security_groups.worker_sg_id
  ecs_execution_role_arn = module.iam.ecs_execution_role_arn
  ecs_task_role_arn      = module.iam.ecs_task_role_arn
  secrets_arn            = aws_secretsmanager_secret.app.arn
  log_retention_days     = 3
  api_cpu                = 256
  api_memory             = 512
  worker_cpu             = 256
  worker_memory          = 512
  api_desired_count      = 1
  worker_desired_count   = 1
  common_tags            = local.common_tags
}

# ── Monitoring: Prometheus + Grafana on EC2 ──
# t3.micro = free tier (750 hrs/month)
# Dual monitoring strategy:
#   1. Prometheus scrapes the Flask /metrics endpoint on ECS tasks
#   2. CloudWatch Logs Insights for log analysis (both use same log groups)
# Grafana visualizes both data sources in one dashboard
module "monitoring" {
  source = "../../modules/monitoring"

  project                = local.project
  environment            = local.environment
  aws_region             = var.aws_region
  vpc_id                 = module.vpc.vpc_id
  public_subnet_id       = module.vpc.public_subnet_ids[0]
  monitoring_sg_id       = module.security_groups.monitoring_sg_id
  ecs_cluster_name       = module.ecs.cluster_name
  grafana_admin_password = data.aws_ssm_parameter.grafana_admin_password.value
  cloudwatch_log_groups  = [
    "/ecs/${local.project}/${local.environment}/api",
    "/ecs/${local.project}/${local.environment}/worker",
    "/ecs/${local.project}/${local.environment}/beat",
    "/aws/vpc/flowlogs/${local.project}-${local.environment}",
  ]
  common_tags = local.common_tags
}
