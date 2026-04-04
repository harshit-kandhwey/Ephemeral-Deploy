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
# Monitoring Module

data "aws_caller_identity" "current" {}
# Prometheus + Grafana on EC2 t3.micro (free tier)
#
# Config files are stored in S3 (s3://<state_bucket>/monitoring/config/)
# and downloaded at EC2 boot time. This keeps user_data under the 16KB limit.
# ─────────────────────────────────────────────

# ── Upload monitoring configs to S3 ──────────────────────────────────────────
# These files are downloaded by the EC2 instance at boot via aws s3 cp.
# Storing them in S3 avoids the 16KB EC2 user_data size limit.
locals {
  config_prefix = "monitoring/config"

  # Static config files uploaded as-is
  static_config_files = {
    "prometheus.yml"             = "${path.module}/files/prometheus.yml"
    "cloudwatch-exporter.yml"    = "${path.module}/files/cloudwatch-exporter.yml"
    "grafana-dashboards.yml"     = "${path.module}/files/grafana-dashboards.yml"
    "nexusdeploy-dashboard.json" = "${path.module}/files/nexusdeploy-dashboard.json"
  }

  # Rendered config files using templatefile() — region injected at deploy time
  # so Grafana gets a valid AWS region without relying on runtime shell substitution
  rendered_config_files = {
    "grafana-datasources.yml" = templatefile("${path.module}/files/grafana-datasources.yml.tpl", {
      aws_region = var.aws_region
    })
  }
}

resource "aws_s3_object" "monitoring_configs_static" {
  for_each = local.static_config_files

  bucket  = var.state_bucket
  key     = "${local.config_prefix}/${each.key}"
  content = file(each.value)
  etag    = filemd5(each.value)
  tags    = var.common_tags
}

resource "aws_s3_object" "monitoring_configs_rendered" {
  for_each = local.rendered_config_files

  bucket  = var.state_bucket
  key     = "${local.config_prefix}/${each.key}"
  content = each.value
  etag    = md5(each.value)
  tags    = var.common_tags
}

# ── IAM Role for the monitoring EC2 instance ─────────────────────────────────
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
      },
      {
        # Download monitoring configs at boot — scoped to monitoring prefix only
        Sid      = "S3MonitoringConfigs"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${var.state_bucket}/monitoring/*"
      },
      {
        # Fetch Grafana password at runtime — avoids embedding secrets in user_data
        Sid      = "SSMGrafanaPassword"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/${var.environment}/monitoring/grafana_password"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "${var.project}-${var.environment}-monitoring"
  role = aws_iam_role.monitoring.name
  tags = var.common_tags
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────
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

resource "aws_instance" "monitoring" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.micro"
  subnet_id              = var.public_subnet_id
  vpc_security_group_ids = [var.monitoring_sg_id]
  iam_instance_profile   = aws_iam_instance_profile.monitoring.name

  user_data = base64encode(templatefile("${path.module}/templates/monitoring-userdata.sh.tpl", {
    project          = var.project
    environment      = var.environment
    aws_region       = var.aws_region
    ecs_cluster_name = var.ecs_cluster_name
    state_bucket     = var.state_bucket
    # grafana_password intentionally omitted — fetched at runtime from SSM
    # to avoid embedding secrets in EC2 user_data (visible in AWS console)
  }))

  # Replace instance when user_data changes (new config = new boot)
  user_data_replace_on_change = true

  # Ensure configs are uploaded to S3 before instance boots
  depends_on = [
    aws_s3_object.monitoring_configs_static,
    aws_s3_object.monitoring_configs_rendered,
  ]

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-monitoring"
  })
}

# ── CloudWatch Alarms ─────────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "ecs_api_cpu_high" {
  alarm_name          = "${var.project}-${var.environment}-api-cpu-high"
  alarm_description   = "ECS API service CPU > 80% for 4 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 120
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"
  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = "${var.project}-${var.environment}-api"
  }
  tags = var.common_tags
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${var.project}-${var.environment}-rds-cpu-high"
  alarm_description   = "RDS CPU > 75%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 75
  treat_missing_data  = "notBreaching"
  dimensions = {
    DBInstanceIdentifier = "${var.project}-${var.environment}-postgres"
  }
  tags = var.common_tags
}

resource "aws_cloudwatch_metric_alarm" "redis_memory_high" {
  alarm_name          = "${var.project}-${var.environment}-redis-memory-high"
  alarm_description   = "Redis memory > 80%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseMemoryUsagePercentage"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"
  dimensions = {
    CacheClusterId = "${var.project}-${var.environment}-redis"
  }
  tags = var.common_tags
}

# ── CloudWatch Dashboard ──────────────────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project}-${var.environment}"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 8, height = 6
        properties = {
          title = "ECS API - CPU & Memory"
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", "${var.project}-${var.environment}-api"],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", "${var.project}-${var.environment}-api"]
          ]
          period = 60, stat = "Average", region = var.aws_region
        }
      },
      {
        type = "metric", x = 8, y = 0, width = 8, height = 6
        properties = {
          title = "RDS - CPU & Connections"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", "${var.project}-${var.environment}-postgres"],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", "${var.project}-${var.environment}-postgres"]
          ]
          period = 60, stat = "Average", region = var.aws_region
        }
      },
      {
        type = "metric", x = 16, y = 0, width = 8, height = 6
        properties = {
          title = "Redis - Memory & Connections"
          metrics = [
            ["AWS/ElastiCache", "DatabaseMemoryUsagePercentage", "CacheClusterId", "${var.project}-${var.environment}-redis"],
            ["AWS/ElastiCache", "CurrConnections", "CacheClusterId", "${var.project}-${var.environment}-redis"]
          ]
          period = 60, stat = "Average", region = var.aws_region
        }
      },
      {
        type = "log", x = 0, y = 6, width = 24, height = 6
        properties = {
          title  = "API Error Logs (last 30 min)"
          query  = "SOURCE '/ecs/${var.project}/${var.environment}/api' | fields @timestamp, @message | filter @message like /ERROR/ | sort @timestamp desc | limit 50"
          region = var.aws_region
          view   = "table"
        }
      }
    ]
  })
}
