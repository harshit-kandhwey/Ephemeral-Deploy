terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ─────────────────────────────────────────────
# RDS Module - PostgreSQL (free-tier eligible)
# ─────────────────────────────────────────────

resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-${var.environment}-db-subnet"
  subnet_ids = var.private_db_subnet_ids

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-db-subnet-group"
  })
}

resource "aws_db_instance" "main" {
  identifier = "${var.project}-${var.environment}-postgres"

  # Engine
  engine         = "postgres"
  engine_version = "15.4"

  # Instance - db.t3.micro is free-tier eligible
  instance_class        = var.db_instance_class
  allocated_storage     = var.db_storage_gb
  max_allocated_storage = var.db_storage_gb * 2 # Auto-scaling cap

  # Credentials (pulled from Secrets Manager by app, set here for RDS)
  db_name  = var.db_name
  username = var.db_master_username
  password = var.db_master_password # Passed from Secrets Manager at apply time

  # Network
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.rds_sg_id]
  publicly_accessible    = false # Never expose DB to internet

  # Backup & maintenance
  backup_retention_period   = var.environment == "prod" ? 7 : 1
  backup_window             = "03:00-04:00"
  maintenance_window        = "sun:05:00-sun:06:00"
  skip_final_snapshot       = var.environment != "prod" # Keep snapshot in prod
  final_snapshot_identifier = var.environment == "prod" ? (var.final_snapshot_identifier != null ? var.final_snapshot_identifier : "${var.project}-${var.environment}-final-snapshot") : null
  deletion_protection       = var.environment == "prod"
  multi_az                  = var.environment == "prod" # HA with automatic failover in prod

  # Storage
  storage_type      = "gp2"
  storage_encrypted = true

  # Performance
  performance_insights_enabled = var.enable_performance_insights != null ? var.enable_performance_insights : var.environment == "prod" # Enable for prod by default

  # Parameter group for PostgreSQL tuning
  parameter_group_name = aws_db_parameter_group.main.name

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-postgres"
  })
}

resource "aws_db_parameter_group" "main" {
  family = "postgres15"
  name   = "${var.project}-${var.environment}-pg15"

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000" # Log queries > 1 second
  }

  tags = var.common_tags
}
