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
# IAM Module - OIDC, ECS roles, least-privilege
# ─────────────────────────────────────────────

# ── GitHub OIDC Provider ──────────────────────
# This allows GitHub Actions to assume AWS roles WITHOUT
# storing any long-lived credentials in GitHub Secrets.
# This is the modern, secure way to authenticate CI/CD.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # GitHub's OIDC thumbprint (stable, published by GitHub)
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = var.common_tags

  lifecycle {
    # bootstrap.sh is the owner of this resource.
    # Terraform imports it for reference but never modifies it.
    ignore_changes = all
  }
}

# ── GitHub Actions Deploy Role ────────────────
# This role is assumed by GitHub Actions via OIDC.
# Only our specific repo/branch can assume it.
resource "aws_iam_role" "github_actions_deploy" {
  name = "${var.project}-github-actions-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # Restrict to allowed branches (security best practice)
            "token.actions.githubusercontent.com:sub" = formatlist("repo:${var.github_org}/${var.github_repo}:ref:refs/heads/%s", var.deploy_branches)
          }
        }
      }
    ]
  })

  tags = var.common_tags

  lifecycle {
    # bootstrap.sh owns this role and its trust policy.
    # Permissions are managed via bootstrap — never overwritten by Terraform.
    ignore_changes = all
  }
}

# ── Deploy Role Policy ────────────────────────
resource "aws_iam_role_policy" "github_actions_deploy" {
  name = "${var.project}-github-actions-deploy-policy"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ECR - authentication (account-level, requires Resource = "*")
      {
        Sid    = "ECRGetAuth"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      # ECR - repository operations (scoped to specific repositories)
      {
        Sid    = "ECRRepoAccess"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:ListImages",
          "ecr:BatchDeleteImage",
          "ecr:DescribeRepositories"
        ]
        Resource = [for repo in var.ecr_repository_names : "arn:aws:ecr:*:*:repository/${var.project}-${repo}"]
      },
      # ECS - deploy services
      {
        Sid    = "ECSAccess"
        Effect = "Allow"
        Action = [
          "ecs:RegisterTaskDefinition",
          "ecs:UpdateService",
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:ListTaskDefinitions"
        ]
        Resource = "*"
      },
      # Terraform state backend
      {
        Sid    = "TerraformStateS3"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.tf_state_bucket}",
          "arn:aws:s3:::${var.tf_state_bucket}/*"
        ]
      },
      # Terraform state locking
      {
        Sid    = "TerraformStateLock"
        Effect = "Allow"
        Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = "arn:aws:dynamodb:*:*:table/${var.tf_lock_table}"
      },
      # Infrastructure: EC2 and VPC (Terraform-managed only)
      {
        Sid    = "EC2VPCManagement"
        Effect = "Allow"
        Action = [
          "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
          "ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress", "ec2:RevokeSecurityGroupEgress",
          "ec2:CreateNetworkInterface", "ec2:DeleteNetworkInterface",
          "ec2:DescribeSecurityGroups", "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSubnets", "ec2:DescribeVpcs",
          "ec2:CreateTags", "ec2:DeleteTags",
          "ec2:DescribeInstances", "ec2:DescribeImages"
        ]
        Resource = "*"
      },
      # Infrastructure: ECS (Terraform-managed resources)
      {
        Sid    = "ECSManagement"
        Effect = "Allow"
        Action = [
          "ecs:CreateCluster", "ecs:DeleteCluster",
          "ecs:UpdateCluster", "ecs:DescribeClusters",
          "ecs:RegisterTaskDefinition", "ecs:DeregisterTaskDefinition",
          "ecs:DescribeTaskDefinition", "ecs:CreateService", "ecs:DeleteService",
          "ecs:UpdateService", "ecs:DescribeServices",
          "ecs:ListClusters", "ecs:ListServices", "ecs:ListTaskDefinitions"
        ]
        Resource = ["arn:aws:ecs:*:*:cluster/${var.project}-*", "arn:aws:ecs:*:*:service/${var.project}-*/*", "arn:aws:ecs:*:*:task-definition/${var.project}-*"]
      },
      # Infrastructure: RDS (Terraform-managed instances)
      {
        Sid    = "RDSManagement"
        Effect = "Allow"
        Action = [
          "rds:CreateDBInstance", "rds:DeleteDBInstance",
          "rds:ModifyDBInstance", "rds:DescribeDBInstances",
          "rds:CreateDBSubnetGroup", "rds:DeleteDBSubnetGroup",
          "rds:CreateDBParameterGroup", "rds:DeleteDBParameterGroup",
          "rds:ModifyDBParameterGroup", "rds:DescribeDBParameterGroups",
          "rds:AddTagsToResource", "rds:RemoveTagsFromResource"
        ]
        Resource = "arn:aws:rds:*:*:db:${var.project}-*"
      },
      # Infrastructure: ElastiCache (Terraform-managed clusters)
      {
        Sid    = "ElastiCacheManagement"
        Effect = "Allow"
        Action = [
          "elasticache:CreateCacheCluster", "elasticache:DeleteCacheCluster",
          "elasticache:ModifyCacheCluster", "elasticache:DescribeCacheClusters",
          "elasticache:CreateCacheSubnetGroup", "elasticache:DeleteCacheSubnetGroup",
          "elasticache:AddTagsToResource", "elasticache:RemoveTagsFromResource"
        ]
        Resource = "arn:aws:elasticache:*:*:cluster:${var.project}-*"
      },
      # Infrastructure: CloudWatch Logs (Terraform-managed log groups)
      {
        Sid    = "CloudWatchLogsManagement"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:DeleteLogGroup",
          "logs:PutRetentionPolicy", "logs:DescribeLogGroups",
          "logs:TagLogGroup", "logs:UntagLogGroup"
        ]
        Resource = "arn:aws:logs:*:*:log-group:/ecs/${var.project}*"
      },
      # Infrastructure: Secrets Manager (read for configuration)
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"
        ]
        Resource = "arn:aws:secretsmanager:*:*:secret:${var.project}/*"
      },
      # Infrastructure: App Auto Scaling (for ECS/RDS)
      {
        Sid    = "AppAutoScalingManagement"
        Effect = "Allow"
        Action = [
          "application-autoscaling:RegisterScalableTarget",
          "application-autoscaling:DeregisterScalableTarget",
          "application-autoscaling:PutScalingPolicy",
          "application-autoscaling:DeleteScalingPolicy",
          "application-autoscaling:DescribeScalableTargets",
          "application-autoscaling:DescribeScalingPolicies"
        ]
        Resource = "arn:aws:application-autoscaling:*:*:*"
      },
      # IAM: Restricted role and policy management (project-scoped)
      {
        Sid    = "IAMRoleManagement"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole",
          "iam:UpdateAssumeRolePolicy", "iam:GetRole",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy",
          "iam:GetRolePolicy"
        ]
        Resource = "arn:aws:iam::*:role/${var.project}-*"
      },
      # IAM: PassRole limited to project-scoped roles (security critical)
      {
        Sid    = "IAMPassRole"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = "arn:aws:iam::*:role/${var.project}-*"
      }
    ]
  })

  lifecycle {
    # bootstrap.sh is the sole owner of this policy.
    # All permission changes go through bootstrap.sh — not Terraform.
    # This prevents Terraform from ever downgrading carefully managed permissions.
    ignore_changes = all
  }
}

# ── ECS Task Execution Role ───────────────────
# This role allows ECS to pull images from ECR and
# write logs to CloudWatch. The ECS agent needs this.
resource "aws_iam_role" "ecs_execution" {
  name = "${var.project}-${var.environment}-ecs-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow ECS to read secrets from Secrets Manager
resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name = "${var.project}-${var.environment}-ecs-secrets"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = var.secrets_arn
    }]
  })
}

# ── ECS Task Role ─────────────────────────────
# This is the role YOUR APPLICATION CODE uses at runtime.
# Principle: only grant what the app actually needs.
resource "aws_iam_role" "ecs_task" {
  name = "${var.project}-${var.environment}-ecs-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

# App can write to S3 (for file attachments)
resource "aws_iam_role_policy" "ecs_task_s3" {
  name = "${var.project}-${var.environment}-task-s3"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
      Resource = "arn:aws:s3:::${var.app_s3_bucket}/*"
    }]
  })
}

# ── VPC Flow Log Role ─────────────────────────
resource "aws_iam_role" "vpc_flow_log" {
  name = "${var.project}-${var.environment}-vpc-flow-log"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "vpc_flow_log" {
  role = aws_iam_role.vpc_flow_log.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      # Scoped to project-specific VPC flow log groups only.
      # The VPC flow logs service writes to /aws/vpc/flowlogs/{project}-{env}.
      Resource = [
        "arn:aws:logs:*:*:log-group:/aws/vpc/flowlogs/${var.project}-*",
        "arn:aws:logs:*:*:log-group:/aws/vpc/flowlogs/${var.project}-*:log-stream:*"
      ]
    }]
  })
}
