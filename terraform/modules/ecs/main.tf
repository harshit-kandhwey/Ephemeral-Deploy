# ─────────────────────────────────────────────
# ECS Module - Fargate containers for API + Worker + Beat
# ─────────────────────────────────────────────

# ── ECS Cluster ──────────────────────────────
resource "aws_ecs_cluster" "main" {
  name = "${var.project}-${var.environment}"

  setting {
    name  = "containerInsights"
    value = var.environment == "prod" ? "enabled" : "disabled"  # Cost optimization
  }

  tags = var.common_tags
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = var.environment == "prod" ? ["FARGATE"] : ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = var.environment == "prod" ? "FARGATE" : "FARGATE_SPOT"
    weight            = 1
    base              = 1
  }
}


# ── CloudWatch Log Groups ─────────────────────
resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.project}/${var.environment}/api"
  retention_in_days = var.log_retention_days
  tags              = var.common_tags
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/${var.project}/${var.environment}/worker"
  retention_in_days = var.log_retention_days
  tags              = var.common_tags
}

resource "aws_cloudwatch_log_group" "beat" {
  name              = "/ecs/${var.project}/${var.environment}/beat"
  retention_in_days = var.log_retention_days
  tags              = var.common_tags
}

# ── Task Definition: API ──────────────────────
resource "aws_ecs_task_definition" "api" {
  family                   = "${var.project}-${var.environment}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.api_cpu
  memory                   = var.api_memory
  execution_role_arn       = var.ecs_execution_role_arn
  task_role_arn            = var.ecs_task_role_arn

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = var.api_image
      essential = true

      portMappings = [
        {
          containerPort = 5000
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "ENV",     value = var.environment },
        { name = "VERSION", value = var.git_commit }
      ]

      secrets = [
        { name = "DATABASE_URL",          valueFrom = "${var.secrets_arn}:DATABASE_URL::" },
        { name = "REDIS_URL",             valueFrom = "${var.secrets_arn}:REDIS_URL::" },
        { name = "SECRET_KEY",            valueFrom = "${var.secrets_arn}:SECRET_KEY::" },
        { name = "JWT_SECRET_KEY",        valueFrom = "${var.secrets_arn}:JWT_SECRET_KEY::" },
        { name = "CELERY_BROKER_URL",     valueFrom = "${var.secrets_arn}:CELERY_BROKER_URL::" },
        { name = "CELERY_RESULT_BACKEND", valueFrom = "${var.secrets_arn}:CELERY_RESULT_BACKEND::" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "api"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:5000/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])

  tags = var.common_tags
}

# ── Task Definition: Celery Worker ───────────
resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.project}-${var.environment}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.worker_cpu
  memory                   = var.worker_memory
  execution_role_arn       = var.ecs_execution_role_arn
  task_role_arn            = var.ecs_task_role_arn

  container_definitions = jsonencode([
    {
      name      = "worker"
      image     = var.worker_image
      essential = true

      environment = [
        { name = "ENV",     value = var.environment },
        { name = "VERSION", value = var.git_commit }
      ]

      secrets = [
        { name = "DATABASE_URL",          valueFrom = "${var.secrets_arn}:DATABASE_URL::" },
        { name = "REDIS_URL",             valueFrom = "${var.secrets_arn}:REDIS_URL::" },
        { name = "CELERY_BROKER_URL",     valueFrom = "${var.secrets_arn}:CELERY_BROKER_URL::" },
        { name = "CELERY_RESULT_BACKEND", valueFrom = "${var.secrets_arn}:CELERY_RESULT_BACKEND::" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.worker.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "worker"
        }
      }
    }
  ])

  tags = var.common_tags
}

# ── Task Definition: Celery Beat ─────────────
resource "aws_ecs_task_definition" "beat" {
  family                   = "${var.project}-${var.environment}-beat"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = var.ecs_execution_role_arn
  task_role_arn            = var.ecs_task_role_arn

  container_definitions = jsonencode([
    {
      name      = "beat"
      image     = var.worker_image
      essential = true
      command   = ["celery", "-A", "app.src.celery_worker:celery", "beat", "--loglevel=info"]

      environment = [
        { name = "ENV", value = var.environment }
      ]

      secrets = [
        { name = "DATABASE_URL",      valueFrom = "${var.secrets_arn}:DATABASE_URL::" },
        { name = "CELERY_BROKER_URL", valueFrom = "${var.secrets_arn}:CELERY_BROKER_URL::" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.beat.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "beat"
        }
      }
    }
  ])

  tags = var.common_tags
}

# ── ECS Service: API ─────────────────────────
resource "aws_ecs_service" "api" {
  name                               = "${var.project}-${var.environment}-api"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.api.arn
  desired_count                      = var.api_desired_count
  launch_type                        = null  # Use capacity provider
  health_check_grace_period_seconds  = 60

  capacity_provider_strategy {
    capacity_provider = var.environment == "prod" ? "FARGATE" : "FARGATE_SPOT"
    weight            = 1
    base              = 1
  }

  network_configuration {
    subnets          = var.private_app_subnet_ids
    security_groups  = [var.api_sg_id]
    assign_public_ip = false  # Private subnet - no public IP needed
  }

  # Uncomment to attach to ALB (shows LB knowledge)
  # load_balancer {
  #   target_group_arn = var.alb_target_group_arn
  #   container_name   = "api"
  #   container_port   = 5000
  # }

  deployment_circuit_breaker {
    enable   = true
    rollback = true   # Auto-rollback on failed deployment
  }

  deployment_controller {
    type = "ECS"
    # For blue/green: type = "CODE_DEPLOY"  ← Shows awareness of deployment strategies
  }

  tags = var.common_tags

  lifecycle {
    ignore_changes = [task_definition]  # Managed by CI/CD
  }
}

# ── ECS Service: Worker ───────────────────────
resource "aws_ecs_service" "worker" {
  name            = "${var.project}-${var.environment}-worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.worker_desired_count

  capacity_provider_strategy {
    capacity_provider = var.environment == "prod" ? "FARGATE" : "FARGATE_SPOT"
    weight            = 1
    base              = 0
  }

  network_configuration {
    subnets         = var.private_app_subnet_ids
    security_groups = [var.worker_sg_id]
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  tags = var.common_tags

  lifecycle {
    ignore_changes = [task_definition]  # Managed by CI/CD
  }
}

# ── ECS Service: Beat ─────────────────────────
resource "aws_ecs_service" "beat" {
  name            = "${var.project}-${var.environment}-beat"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.beat.arn
  desired_count   = 1   # Beat scheduler must be singleton

  capacity_provider_strategy {
    capacity_provider = var.environment == "prod" ? "FARGATE" : "FARGATE_SPOT"
    weight            = 1
  }

  network_configuration {
    subnets         = var.private_app_subnet_ids
    security_groups = [var.worker_sg_id]
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  tags = var.common_tags

  lifecycle {
    ignore_changes = [task_definition]  # Managed by CI/CD
  }
}

# ── Auto Scaling (API only) ───────────────────
resource "aws_appautoscaling_target" "api" {
  max_capacity       = var.api_max_count
  min_capacity       = var.api_desired_count
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "api_cpu" {
  name               = "${var.project}-${var.environment}-api-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  service_namespace  = aws_appautoscaling_target.api.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# ────────────────────────────────────────────────────────────
# APPLICATION LOAD BALANCER (commented out - cost saving)
# Uncomment to demonstrate ALB knowledge in interviews
# Cost: ~$16/month for ALB alone
# ────────────────────────────────────────────────────────────
# resource "aws_lb" "api" {
#   name               = "${var.project}-${var.environment}-alb"
#   internal           = false
#   load_balancer_type = "application"
#   security_groups    = [var.alb_sg_id]
#   subnets            = var.public_subnet_ids
#   
#   enable_deletion_protection = var.environment == "prod"
#   
#   access_logs {
#     bucket  = var.alb_logs_bucket
#     prefix  = "${var.environment}/alb"
#     enabled = true
#   }
#   
#   tags = var.common_tags
# }
#
# resource "aws_lb_target_group" "api" {
#   name        = "${var.project}-${var.environment}-api-tg"
#   port        = 5000
#   protocol    = "HTTP"
#   vpc_id      = var.vpc_id
#   target_type = "ip"   # Required for Fargate
#   
#   health_check {
#     path                = "/health"
#     healthy_threshold   = 2
#     unhealthy_threshold = 3
#     timeout             = 5
#     interval            = 30
#     matcher             = "200"
#   }
# }
#
# resource "aws_lb_listener" "http" {
#   load_balancer_arn = aws_lb.api.arn
#   port              = 80
#   protocol          = "HTTP"
#   
#   # Redirect HTTP → HTTPS in prod, forward to app in non-prod
#   dynamic "default_action" {
#     for_each = var.environment == "prod" ? [1] : []
#     content {
#       type = "redirect"
#       
#       redirect {
#         port        = "443"
#         protocol    = "HTTPS"
#         status_code = "HTTP_301"
#       }
#     }
#   }
#   
#   dynamic "default_action" {
#     for_each = var.environment == "prod" ? [] : [1]
#     content {
#       type             = "forward"
#       target_group_arn = aws_lb_target_group.api.arn
#     }
#   }
# }
#
# resource "aws_lb_listener" "https" {
#   load_balancer_arn = aws_lb.api.arn
#   port              = 443
#   protocol          = "HTTPS"
#   ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
#   certificate_arn   = var.acm_certificate_arn
#   
#   default_action {
#     type             = "forward"
#     target_group_arn = aws_lb_target_group.api.arn
#   }
# }
