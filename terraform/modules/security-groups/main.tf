# ─────────────────────────────────────────────
# Security Groups - Least-privilege network rules
# ─────────────────────────────────────────────

# ── ALB Security Group ────────────────────────
# (Commented out since ALB is optional, but defined for completeness)
# resource "aws_security_group" "alb" {
#   name        = "${var.project}-${var.environment}-alb-sg"
#   description = "Allow inbound HTTP/HTTPS from internet to ALB"
#   vpc_id      = var.vpc_id
#
#   ingress {
#     description = "HTTP from internet"
#     from_port   = 80
#     to_port     = 80
#     protocol    = "tcp"
#     cidr_blocks = ["0.0.0.0/0"]
#   }
#
#   ingress {
#     description = "HTTPS from internet"
#     from_port   = 443
#     to_port     = 443
#     protocol    = "tcp"
#     cidr_blocks = ["0.0.0.0/0"]
#   }
#
#   egress {
#     from_port   = 0
#     to_port     = 0
#     protocol    = "-1"
#     cidr_blocks = ["0.0.0.0/0"]
#   }
#
#   tags = merge(var.common_tags, { Name = "${var.project}-${var.environment}-alb-sg" })
# }

# ── API Security Group ────────────────────────
resource "aws_security_group" "api" {
  name        = "${var.project}-${var.environment}-api-sg"
  description = "ECS API tasks - accepts traffic from within VPC only"
  vpc_id      = var.vpc_id

  # Inbound: only from VPC CIDR (or ALB if enabled)
  ingress {
    description = "API port from VPC"
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    # When ALB is enabled, replace with: security_groups = [aws_security_group.alb.id]
  }

  # Egress: scoped to least-privilege destinations only.
  # API tasks need:
  #   1. PostgreSQL and Redis — within the VPC
  #   2. HTTPS to AWS APIs   — ECR image pulls, Secrets Manager, SSM, CloudWatch
  #      (NAT Gateway or VPC endpoints forward these; dest is still 0.0.0.0/0
  #       at the SG layer since AWS service IPs are not fixed CIDR blocks)
  egress {
    description = "PostgreSQL and Redis within VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "HTTPS for AWS API calls (ECR, Secrets Manager, SSM, CloudWatch)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-api-sg"
  })
}

# ── Worker Security Group ─────────────────────
resource "aws_security_group" "worker" {
  name        = "${var.project}-${var.environment}-worker-sg"
  description = "Celery workers - no inbound, only outbound to Redis/DB"
  vpc_id      = var.vpc_id

  # No inbound rules - workers initiate all connections outbound

  egress {
    description = "Redis access"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "PostgreSQL access"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "HTTPS for AWS API calls (ECR, Secrets Manager, etc.)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-worker-sg"
  })
}

# ── RDS Security Group ────────────────────────
resource "aws_security_group" "rds" {
  name        = "${var.project}-${var.environment}-rds-sg"
  description = "RDS PostgreSQL - only accepts from app and worker SGs"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from API tasks"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.api.id, aws_security_group.worker.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-rds-sg"
  })
}

# ── Redis/ElastiCache Security Group ─────────
resource "aws_security_group" "redis" {
  name        = "${var.project}-${var.environment}-redis-sg"
  description = "Redis - only accepts from app and worker SGs"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from API and worker tasks"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.api.id, aws_security_group.worker.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-redis-sg"
  })
}

# ── Monitoring Security Group ─────────────────
# Only created when monitoring_enabled = true
resource "aws_security_group" "monitoring" {
  count = var.monitoring_enabled ? 1 : 0

  name        = "${var.project}-${var.environment}-monitoring-sg"
  description = "Prometheus and Grafana - inbound from internet on specific ports only"
  vpc_id      = var.vpc_id

  # Grafana UI - accessible from internet (password-protected)
  ingress {
    description = "Grafana from internet"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Prometheus UI - restrict to your IP in real usage
  # For demo purposes, open to internet
  ingress {
    description = "Prometheus from internet"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Node exporter - only within VPC (Prometheus scrapes this internally)
  ingress {
    description = "Node exporter from VPC"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-monitoring-sg"
  })
}
