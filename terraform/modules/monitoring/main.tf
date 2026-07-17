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
# Config files are stored in S3 (s3://<state_bucket>/monitoring/config/<env>/)
# and downloaded at EC2 boot time. This keeps user_data under the 16KB limit.
# ─────────────────────────────────────────────

# ── Upload monitoring configs to S3 ──────────────────────────────────────────
# These files are downloaded by the EC2 instance at boot via aws s3 cp.
# Storing them in S3 avoids the 16KB EC2 user_data size limit.
locals {
  # Env-scoped so each environment's monitoring artifacts are isolated in S3.
  # This lets a cleanup of one env (aws s3 rm .../monitoring/config/<env>/)
  # never touch another env's configs — critical when dev and staging run
  # in parallel.
  config_prefix = "monitoring/config/${var.environment}"

  # Static config files uploaded as-is
  static_config_files = {
    "prometheus.yml"             = "${path.module}/files/prometheus.yml"
    "cloudwatch-exporter.yml"    = "${path.module}/files/cloudwatch-exporter.yml"
    "grafana-dashboards.yml"     = "${path.module}/files/grafana-dashboards.yml"
    "nexusdeploy-dashboard.json" = "${path.module}/files/nexusdeploy-dashboard.json"
    # Static frontend console served by nginx (reverse-proxies /api to ECS tasks)
    "frontend-index.html" = "${path.module}/files/frontend/index.html"
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
        # YACE needs tag:GetResources to discover resources via searchTags
        # Plus describe APIs for ECS, RDS, ElastiCache metric collection
        Sid    = "YACEDiscovery"
        Effect = "Allow"
        Action = [
          "tag:GetResources",
          "iam:ListAccountAliases",
          "ecs:ListTasks",
          "ecs:DescribeTasks",
          "ecs:ListServices",
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:ListClusters",
          "ecs:DescribeClusters",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeRegions",
          "rds:DescribeDBInstances",
          "rds:ListTagsForResource",
          "elasticache:DescribeCacheClusters",
          "elasticache:ListTagsForResource"
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
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
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
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = var.public_subnet_id
  vpc_security_group_ids = [var.monitoring_sg_id]
  iam_instance_profile   = aws_iam_instance_profile.monitoring.name

  # gzip + base64: cloud-init auto-decompresses gzipped user-data, and EC2
  # measures the COMPRESSED size against its 16 KB limit. The plain script
  # exceeds 16 KB (largely repeated box-drawing separators), so base64encode
  # of the raw text fails aws_instance's 0-16384 validation; gzip crushes it.
  user_data_base64 = base64gzip(templatefile("${path.module}/templates/monitoring-userdata.sh.tpl", {
    project           = var.project
    environment       = var.environment
    aws_region        = var.aws_region
    ecs_cluster_names = join(" ", var.ecs_cluster_names)
    state_bucket      = var.state_bucket
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

# ── SNS: alarm notifications ──────────────────────────────────────────────────
# The alarms below route both ALARM and OK transitions here. The topic itself is
# free; email delivery is free; the alarms already bill (~$0.10 each) whether or
# not anything is subscribed — so wiring this adds no recurring cost and just
# makes the alarms actually notify. A blank alert_email still creates and wires
# the topic (alarms show up in the SNS console); set alert_email to also get mail.
#
# Left on the AWS-managed SSE default (unencrypted). Encrypting with the built-in
# alias/aws/sns key would BLOCK CloudWatch from publishing (its key policy omits
# cloudwatch.amazonaws.com), and a customer-managed key is ~$1/mo — deliberately
# not worth it for alarm fan-out on a demo stack.
#checkov:skip=CKV_AWS_26:CloudWatch cannot publish to an aws/sns-encrypted topic; CMK not justified here
resource "aws_sns_topic" "alerts" {
  name = "${var.project}-${var.environment}-alerts"
  tags = var.common_tags
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── CloudWatch Alarms ─────────────────────────────────────────────────────────
# One API CPU alarm per cluster: blue-green environments run two clusters
# (one per slot) and the active one alternates, so both must be watched.
# The idle slot has desired_count=0 → no data → notBreaching keeps it green.
resource "aws_cloudwatch_metric_alarm" "ecs_api_cpu_high" {
  for_each = toset(var.ecs_cluster_names)

  alarm_name          = "${each.value}-api-cpu-high"
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
    ClusterName = each.value
    ServiceName = "${each.value}-api"
  }
  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
  tags          = var.common_tags
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
  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
  tags          = var.common_tags
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
  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
  tags          = var.common_tags
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
          # One line per slot cluster — whichever slot is active shows data
          metrics = concat(
            [for c in var.ecs_cluster_names : ["AWS/ECS", "CPUUtilization", "ClusterName", c, "ServiceName", "${c}-api"]],
            [for c in var.ecs_cluster_names : ["AWS/ECS", "MemoryUtilization", "ClusterName", c, "ServiceName", "${c}-api"]]
          )
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
          title = "API Error Logs (last 30 min)"
          # Log groups are per slot: /ecs/<project>/<cluster minus project prefix>/api
          query  = "${join(" | ", [for c in var.ecs_cluster_names : "SOURCE '/ecs/${var.project}/${trimprefix(c, "${var.project}-")}/api'"])} | fields @timestamp, @message | filter @message like /ERROR/ | sort @timestamp desc | limit 50"
          region = var.aws_region
          view   = "table"
        }
      }
    ]
  })
}
