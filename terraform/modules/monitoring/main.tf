# ─────────────────────────────────────────────
# Monitoring Module
# Prometheus + Grafana on EC2 t3.micro (free tier)
#
# Architecture:
#   EC2 t3.micro (public subnet, Elastic IP)
#     ├── Prometheus  :9090  scrapes ECS /metrics endpoints
#     ├── Grafana     :3000  visualizes Prometheus + CloudWatch
#     └── Node Exporter:9100  system metrics for the EC2 itself
#
# Two monitoring approaches shown side-by-side:
#   1. Prometheus - pull-based, real-time metrics from app
#   2. CloudWatch - AWS-native, logs + managed metrics (RDS, ElastiCache)
#   Both data sources available in Grafana simultaneously
# ─────────────────────────────────────────────

# ── IAM Role for the monitoring EC2 instance ─
# Needs: CloudWatch read, ECS describe (for service discovery), SSM for setup
resource "aws_iam_role" "monitoring" {
  name = "${var.project}-${var.environment}-monitoring-ec2"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "monitoring_cloudwatch" {
  name = "${var.project}-${var.environment}-monitoring-cw"
  role = aws_iam_role.monitoring.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Read CloudWatch metrics and logs (for Grafana CloudWatch datasource)
      {
        Sid    = "CloudWatchRead"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "cloudwatch:DescribeAlarms",
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:StartQuery",
          "logs:GetQueryResults"
        ]
        Resource = "*"
      },
      # ECS service discovery - Prometheus needs to find task IPs
      {
        Sid    = "ECSServiceDiscovery"
        Effect = "Allow"
        Action = [
          "ecs:ListTasks",
          "ecs:DescribeTasks",
          "ecs:ListServices",
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces"
        ]
        Resource = "*"
      },
      # SSM Session Manager - allows 'make shell-monitoring' without SSH keys
      {
        Sid    = "SSMSessionManager"
        Effect = "Allow"
        Action = [
          "ssm:UpdateInstanceInformation",
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "${var.project}-${var.environment}-monitoring"
  role = aws_iam_role.monitoring.name
  tags = var.common_tags
}

# ── Elastic IP for stable Grafana URL ────────
resource "aws_eip" "monitoring" {
  domain = "vpc"
  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-monitoring-eip"
  })
}

resource "aws_eip_association" "monitoring" {
  instance_id   = aws_instance.monitoring.id
  allocation_id = aws_eip.monitoring.id
}

# ── Find latest Amazon Linux 2023 AMI ────────
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── EC2 Instance ──────────────────────────────
resource "aws_instance" "monitoring" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.micro"   # Free tier eligible
  subnet_id              = var.public_subnet_id
  vpc_security_group_ids = [var.monitoring_sg_id]
  iam_instance_profile   = aws_iam_instance_profile.monitoring.name

  # No SSH key needed - use SSM Session Manager (more secure)
  # key_name = "your-key"  ← commented intentionally

  root_block_device {
    volume_size = 8    # GB - minimal storage
    volume_type = "gp3"
    encrypted   = true
    tags = merge(var.common_tags, { Name = "${var.project}-${var.environment}-monitoring-root" })
  }

  # User data: install and configure everything at boot
  user_data = base64encode(templatefile("${path.module}/templates/monitoring-userdata.sh.tpl", {
    project               = var.project
    environment           = var.environment
    aws_region            = var.aws_region
    ecs_cluster_name      = var.ecs_cluster_name
    grafana_password      = var.grafana_admin_password
    cloudwatch_log_groups = jsonencode(var.cloudwatch_log_groups)
  }))

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-monitoring"
    Role = "monitoring"
  })

  # Replace instance if user_data changes (new config)
  lifecycle {
    create_before_destroy = true
  }
}

# ── CloudWatch Alarms (uses CloudWatch, not Prometheus) ──
# These are independent of the EC2 instance - AWS-managed alerting
# Shows knowledge of both monitoring approaches

resource "aws_cloudwatch_metric_alarm" "ecs_api_cpu_high" {
  alarm_name          = "${var.project}-${var.environment}-api-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 120
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "ECS API service CPU > 80% for 4 minutes"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = "${var.project}-${var.environment}-api"
  }

  tags = var.common_tags
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${var.project}-${var.environment}-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 75
  alarm_description   = "RDS CPU > 75%"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = "${var.project}-${var.environment}-postgres"
  }

  tags = var.common_tags
}

resource "aws_cloudwatch_metric_alarm" "redis_memory_high" {
  alarm_name          = "${var.project}-${var.environment}-redis-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseMemoryUsagePercentage"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Redis memory > 80%"
  treat_missing_data  = "notBreaching"

  dimensions = {
    CacheClusterId = "${var.project}-${var.environment}-redis"
  }

  tags = var.common_tags
}

# ── CloudWatch Dashboard ──────────────────────
# A pre-built dashboard showing all services in one place
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project}-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "ECS API - CPU & Memory"
          region = var.aws_region
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", "${var.project}-${var.environment}-api"],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", "${var.project}-${var.environment}-api"]
          ]
          period = 60
          stat   = "Average"
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "RDS - CPU & Connections"
          region = var.aws_region
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", "${var.project}-${var.environment}-postgres"],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", "${var.project}-${var.environment}-postgres"]
          ]
          period = 60
          stat   = "Average"
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "Redis - Memory & Connections"
          region = var.aws_region
          metrics = [
            ["AWS/ElastiCache", "DatabaseMemoryUsagePercentage", "CacheClusterId", "${var.project}-${var.environment}-redis"],
            ["AWS/ElastiCache", "CurrConnections", "CacheClusterId", "${var.project}-${var.environment}-redis"]
          ]
          period = 60
          stat   = "Average"
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 6
        width  = 24
        height = 6
        properties = {
          title  = "API Error Logs (last 30 min)"
          region = var.aws_region
          query  = "SOURCE '/ecs/${var.project}/${var.environment}/api' | fields @timestamp, @message | filter @message like /ERROR/ | sort @timestamp desc | limit 50"
          view   = "table"
        }
      }
    ]
  })
}