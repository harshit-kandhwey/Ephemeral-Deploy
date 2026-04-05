# ─────────────────────────────────────────────
# VPC Module - Isolated networking per environment
# ─────────────────────────────────────────────

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ── VPC ──────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-vpc"
  })
}

# ── Internet Gateway ──────────────────────────
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-igw"
  })
}

# ── Public Subnets (API / Load Balancer) ─────
resource "aws_subnet" "public" {
  count = length(var.availability_zones)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-public-${var.availability_zones[count.index]}"
    Tier = "public"
  })
}

# ── Private Subnets (ECS Tasks / App Layer) ──
resource "aws_subnet" "private_app" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + length(var.availability_zones))
  availability_zone = var.availability_zones[count.index]

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-private-app-${var.availability_zones[count.index]}"
    Tier = "private-app"
  })
}

# ── Private Subnets (RDS / Database Layer) ───
resource "aws_subnet" "private_db" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + (length(var.availability_zones) * 2))
  availability_zone = var.availability_zones[count.index]

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-private-db-${var.availability_zones[count.index]}"
    Tier = "private-db"
  })
}

# ── Private Subnets (Cache / Redis Layer) ────
resource "aws_subnet" "private_cache" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + (length(var.availability_zones) * 3))
  availability_zone = var.availability_zones[count.index]

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-private-cache-${var.availability_zones[count.index]}"
    Tier = "private-cache"
  })
}

# ── NAT Gateway (single, cost-optimized) ─────
# NOTE: In production with HA requirements, use one NAT GW per AZ.
# For cost optimization, we use a single NAT GW for non-prod.
resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-nat-eip"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  count = var.enable_nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-nat"
  })

  depends_on = [aws_internet_gateway.main]
}

# ── Route Tables ─────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-rt-public"
  })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.main[0].id
    }
  }

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-rt-private"
  })
}

# ── Route Table Associations ─────────────────
resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_app" {
  count          = length(aws_subnet.private_app)
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_db" {
  count          = length(aws_subnet.private_db)
  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_cache" {
  count          = length(aws_subnet.private_cache)
  subnet_id      = aws_subnet.private_cache[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── VPC Flow Logs (security/observability) ───
resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/flowlogs/${var.project}-${var.environment}"
  retention_in_days = var.log_retention_days

  tags = var.common_tags
}

resource "aws_flow_log" "main" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = var.flow_log_traffic_type
  iam_role_arn    = var.flow_log_role_arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-flow-logs"
  })
}

# ── VPC Endpoints ─────────────────────────────────────────────────────────────
# Interface endpoints allow ECS tasks in private subnets to reach AWS APIs
# without a NAT Gateway. Cheaper than NAT (~$0.01/hr each vs $0.045/hr NAT).
#
# Required for ECS Fargate:
#   ecr.api       — image pull authentication
#   ecr.dkr       — image layer download
#   logs          — CloudWatch log streaming from containers
#   secretsmanager— app secrets fetched at task startup
#   ssm           — SSM parameter store access
#   s3 (Gateway)  — ECR image layer storage; free, no hourly charge

resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project}-${var.environment}-vpc-endpoints-sg"
  description = "Allow HTTPS from within VPC to AWS service endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-vpc-endpoints-sg"
  })
}

locals {
  # Interface endpoints — one per service, shared across all private subnets
  interface_endpoints = {
    ecr_api        = "com.amazonaws.${var.aws_region}.ecr.api"
    ecr_dkr        = "com.amazonaws.${var.aws_region}.ecr.dkr"
    logs           = "com.amazonaws.${var.aws_region}.logs"
    secretsmanager = "com.amazonaws.${var.aws_region}.secretsmanager"
    ssm            = "com.amazonaws.${var.aws_region}.ssm"
    ssmmessages    = "com.amazonaws.${var.aws_region}.ssmmessages"
    ec2messages    = "com.amazonaws.${var.aws_region}.ec2messages"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.main.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private_app[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-endpoint-${each.key}"
  })
}

# S3 Gateway endpoint — free, no hourly charge, routes S3 traffic via AWS backbone
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(var.common_tags, {
    Name = "${var.project}-${var.environment}-endpoint-s3"
  })
}
