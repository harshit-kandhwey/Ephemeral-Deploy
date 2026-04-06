#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# NexusDeploy Resource Status Checker — COMPREHENSIVE
# Checks every resource Terraform creates so nothing is missed after cleanup
# Usage: MSYS_NO_PATHCONV=1 bash scripts/check_resources.sh [--env dev]
# ─────────────────────────────────────────────────────────────────────────────

PROJECT="${PROJECT:-nexusdeploy}"
ENV="${ENV:-dev}"
REGION="${REGION:-us-east-1}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --env)     ENV="$2";     shift 2 ;;
    --region)  REGION="$2";  shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

TOTAL=0; OK=0; WARN=0; FAIL=0

row() {
  local name="$1" status="$2" detail="${3:-}"
  local color icon
  ((TOTAL++))
  case "$status" in
    OK|active|available|exists|ACTIVE|RUNNING|Complete|attached|enabled)
      color="$GREEN"; icon="✅"; ((OK++)) ;;
    MISSING|NOT_FOUND|INACTIVE|deleted|none)
      color="$RED";   icon="❌"; ((FAIL++)) ;;
    *)
      color="$YELLOW"; icon="⚠️ "; ((WARN++)) ;;
  esac
  printf "  ${icon}  %-48s ${color}%-18s${NC} ${DIM}%s${NC}\n" \
    "$name" "$status" "$detail"
}

divider() {
  echo -e "\n${BOLD}${CYAN}  ▸ $*${NC}"
  printf "  %s\n" "$(printf '─%.0s' {1..80})"
}

aws_q() { aws "$@" 2>/dev/null || echo ""; }

echo ""
echo -e "${BOLD}$(printf '═%.0s' {1..80})${NC}"
echo -e "${BOLD}  NexusDeploy Resource Status — $PROJECT/$ENV ($REGION)${NC}"
echo -e "${BOLD}$(printf '═%.0s' {1..80})${NC}"
printf "  %-4s  %-48s %-18s %s\n" "" "Resource" "Status" "Detail"
printf "  %s\n" "$(printf '─%.0s' {1..80})"

# ══════════════════════════════════════════════════════════════════════════════
# ECS
# ══════════════════════════════════════════════════════════════════════════════
divider "ECS"

CLUSTER_OUT=$(aws_q ecs describe-clusters --clusters "${PROJECT}-${ENV}" \
  --region "$REGION" \
  --query 'clusters[0].{p:pendingTasksCount,r:runningTasksCount,s:status,v:activeServicesCount}' \
  --output text)
if [[ -z "$CLUSTER_OUT" ]]; then
  row "Cluster: ${PROJECT}-${ENV}" "MISSING"
else
  read -r pending running status svcs <<< "$CLUSTER_OUT"
  row "Cluster: ${PROJECT}-${ENV}" "$status" "services=$svcs running=$running pending=$pending"
fi

for svc in api worker beat; do
  SVC_NAME="${PROJECT}-${ENV}-${svc}"
  SVC_OUT=$(aws_q ecs describe-services \
    --cluster "${PROJECT}-${ENV}" --services "$SVC_NAME" --region "$REGION" \
    --query 'services[0].{d:desiredCount,f:deployments[0].failedTasks,r:runningCount,s:status}' \
    --output text)
  if [[ -z "$SVC_OUT" || "$SVC_OUT" == "None"* ]]; then
    row "Service: $SVC_NAME" "MISSING"
  else
    read -r desired failed running svc_status <<< "$SVC_OUT"
    detail="running=${running:-0}/${desired:-0} failed=${failed:-0}"
    if [[ "$svc_status" == "ACTIVE" && "${running:-0}" -eq "${desired:-1}" && "${running:-0}" -gt 0 ]]; then
      row "Service: $SVC_NAME" "RUNNING" "$detail"
    else
      row "Service: $SVC_NAME" "${svc_status:-MISSING}" "$detail"
    fi
  fi
done

# Task definitions
for svc in api worker beat; do
  TD=$(aws_q ecs describe-task-definition \
    --task-definition "${PROJECT}-${ENV}-${svc}" --region "$REGION" \
    --query 'taskDefinition.{r:revision,s:status}' --output text)
  if [[ -z "$TD" ]]; then
    row "Task Def: ${PROJECT}-${ENV}-${svc}" "MISSING"
  else
    read -r rev status <<< "$TD"
    row "Task Def: ${PROJECT}-${ENV}-${svc}" "$status" "revision=$rev"
  fi
done

# ══════════════════════════════════════════════════════════════════════════════
# CloudWatch Logs
# ══════════════════════════════════════════════════════════════════════════════
divider "CloudWatch Log Groups"

for lg in \
  "/ecs/${PROJECT}/${ENV}/api" \
  "/ecs/${PROJECT}/${ENV}/worker" \
  "/ecs/${PROJECT}/${ENV}/beat" \
  "/aws/vpc/flowlogs/${PROJECT}-${ENV}"; do
  FOUND=$(aws_q logs describe-log-groups \
    --log-group-name-prefix "$lg" --region "$REGION" \
    --query 'logGroups[0].logGroupName' --output text)
  if [[ -n "$FOUND" && "$FOUND" != "None" ]]; then
    row "Log Group: $lg" "exists"
  else
    row "Log Group: $lg" "MISSING"
  fi
done

# ══════════════════════════════════════════════════════════════════════════════
# CloudWatch Alarms
# ══════════════════════════════════════════════════════════════════════════════
divider "CloudWatch Alarms"

for alarm in \
  "${PROJECT}-${ENV}-api-cpu-high" \
  "${PROJECT}-${ENV}-rds-cpu-high" \
  "${PROJECT}-${ENV}-redis-memory-high"; do
  STATE=$(aws_q cloudwatch describe-alarms \
    --alarm-names "$alarm" --region "$REGION" \
    --query 'MetricAlarms[0].StateValue' --output text)
  if [[ -z "$STATE" || "$STATE" == "None" ]]; then
    row "Alarm: $alarm" "MISSING"
  else
    row "Alarm: $alarm" "$STATE"
  fi
done

# ══════════════════════════════════════════════════════════════════════════════
# CloudWatch Dashboard
# ══════════════════════════════════════════════════════════════════════════════
divider "CloudWatch Dashboard"

DASH=$(aws_q cloudwatch get-dashboard \
  --dashboard-name "${PROJECT}-${ENV}" --region "$REGION" \
  --query 'DashboardName' --output text)
if [[ -n "$DASH" && "$DASH" != "None" ]]; then
  row "Dashboard: ${PROJECT}-${ENV}" "exists"
else
  row "Dashboard: ${PROJECT}-${ENV}" "MISSING"
fi

# ══════════════════════════════════════════════════════════════════════════════
# RDS
# ══════════════════════════════════════════════════════════════════════════════
divider "RDS"

RDS_OUT=$(aws_q rds describe-db-instances \
  --db-instance-identifier "${PROJECT}-${ENV}-postgres" --region "$REGION" \
  --query 'DBInstances[0].{c:DBInstanceClass,e:EngineVersion,s:DBInstanceStatus}' \
  --output text)
if [[ -z "$RDS_OUT" ]]; then
  row "RDS: ${PROJECT}-${ENV}-postgres" "MISSING"
else
  read -r class engine status <<< "$RDS_OUT"
  row "RDS: ${PROJECT}-${ENV}-postgres" "$status" "pg=$engine $class"
fi

for name in "${PROJECT}-${ENV}-pg15" "${PROJECT}-${ENV}-db-subnet"; do
  type="parameter-group"
  [[ "$name" == *"subnet"* ]] && type="subnet-group"
  if [[ "$type" == "parameter-group" ]]; then
    OUT=$(aws_q rds describe-db-parameter-groups \
      --db-parameter-group-name "$name" --region "$REGION" \
      --query 'DBParameterGroups[0].DBParameterGroupName' --output text)
  else
    OUT=$(aws_q rds describe-db-subnet-groups \
      --db-subnet-group-name "$name" --region "$REGION" \
      --query 'DBSubnetGroups[0].SubnetGroupStatus' --output text)
  fi
  [[ -n "$OUT" && "$OUT" != "None" ]] \
    && row "RDS $type: $name" "${OUT:-exists}" \
    || row "RDS $type: $name" "MISSING"
done

# ══════════════════════════════════════════════════════════════════════════════
# ElastiCache
# ══════════════════════════════════════════════════════════════════════════════
divider "ElastiCache"

REDIS_OUT=$(aws_q elasticache describe-cache-clusters \
  --cache-cluster-id "${PROJECT}-${ENV}-redis" --region "$REGION" \
  --query 'CacheClusters[0].{e:EngineVersion,s:CacheClusterStatus,t:CacheNodeType}' \
  --output text)
if [[ -z "$REDIS_OUT" ]]; then
  row "Redis: ${PROJECT}-${ENV}-redis" "MISSING"
else
  read -r engine node_type status <<< "$REDIS_OUT"
  row "Redis: ${PROJECT}-${ENV}-redis" "$status" "redis=$engine $node_type"
fi

CACHE_SG=$(aws_q elasticache describe-cache-subnet-groups \
  --cache-subnet-group-name "${PROJECT}-${ENV}-cache-subnet" --region "$REGION" \
  --query 'CacheSubnetGroups[0].CacheSubnetGroupName' --output text)
[[ -n "$CACHE_SG" && "$CACHE_SG" != "None" ]] \
  && row "Cache Subnet Group: ${PROJECT}-${ENV}-cache-subnet" "exists" \
  || row "Cache Subnet Group: ${PROJECT}-${ENV}-cache-subnet" "MISSING"

# ══════════════════════════════════════════════════════════════════════════════
# VPC & Networking
# ══════════════════════════════════════════════════════════════════════════════
divider "VPC & Networking"

VPC_ID=$(aws_q ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Environment,Values=$ENV" \
  --query 'Vpcs[0].VpcId' --output text)

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  row "VPC: ${PROJECT}-${ENV}" "MISSING"
  row "Internet Gateway" "MISSING" "no VPC"
  row "Public Subnets" "MISSING" "no VPC"
  row "Private App Subnets" "MISSING" "no VPC"
  row "Private DB Subnets" "MISSING" "no VPC"
  row "Private Cache Subnets" "MISSING" "no VPC"
  row "Route Tables" "MISSING" "no VPC"
  row "VPC Flow Log" "MISSING" "no VPC"
  row "VPC Endpoints" "MISSING" "no VPC"
else
  row "VPC: ${PROJECT}-${ENV}" "exists" "$VPC_ID"

  # IGW
  IGW=$(aws_q ec2 describe-internet-gateways --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[0].InternetGatewayId' --output text)
  [[ -n "$IGW" && "$IGW" != "None" ]] \
    && row "Internet Gateway" "attached" "$IGW" \
    || row "Internet Gateway" "MISSING"

  # Subnets by tier
  for tier in public private-app private-db private-cache; do
    COUNT=$(aws_q ec2 describe-subnets --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Tier,Values=$tier" \
      --query 'length(Subnets)' --output text)
    [[ "${COUNT:-0}" -gt 0 ]] \
      && row "Subnets ($tier)" "exists" "${COUNT} subnets" \
      || row "Subnets ($tier)" "MISSING"
  done

  # Route tables
  RT_COUNT=$(aws_q ec2 describe-route-tables --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Project,Values=$PROJECT" \
    --query 'length(RouteTables)' --output text)
  [[ "${RT_COUNT:-0}" -gt 0 ]] \
    && row "Route Tables" "exists" "${RT_COUNT} tables" \
    || row "Route Tables" "MISSING"

  # Flow log
  FL=$(aws_q ec2 describe-flow-logs --region "$REGION" \
    --filter "Name=resource-id,Values=$VPC_ID" \
    --query 'FlowLogs[0].FlowLogStatus' --output text)
  [[ -n "$FL" && "$FL" != "None" ]] \
    && row "VPC Flow Log" "$FL" \
    || row "VPC Flow Log" "MISSING"

  # VPC Endpoints
  ENDPOINTS=$(aws_q ec2 describe-vpc-endpoints --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'VpcEndpoints[?State!=`deleted`].{n:ServiceName,s:State}' \
    --output text)
  if [[ -z "$ENDPOINTS" ]]; then
    row "VPC Endpoints" "MISSING" "ECS tasks cannot reach AWS APIs"
  else
    while IFS=$'\t' read -r svc_name ep_state; do
      [[ -z "$svc_name" ]] && continue
      short="${svc_name##*.}"
      row "Endpoint: $short" "$ep_state"
    done <<< "$ENDPOINTS"
  fi

  # Security Groups
  SG_COUNT=$(aws_q ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Project,Values=$PROJECT" \
    --query 'length(SecurityGroups)' --output text)
  [[ "${SG_COUNT:-0}" -gt 0 ]] \
    && row "Security Groups" "exists" "${SG_COUNT} groups" \
    || row "Security Groups" "MISSING"
fi

# ══════════════════════════════════════════════════════════════════════════════
# ECR
# ══════════════════════════════════════════════════════════════════════════════
divider "ECR"

for repo in api worker; do
  REPO_NAME="${PROJECT}-${repo}-${ENV}"
  IMG_COUNT=$(aws_q ecr describe-images \
    --repository-name "$REPO_NAME" --region "$REGION" \
    --query 'length(imageDetails)' --output text)
  if [[ -z "$IMG_COUNT" ]]; then
    row "ECR Repo: $REPO_NAME" "MISSING"
  else
    # Check lifecycle policy
    LC=$(aws_q ecr get-lifecycle-policy \
      --repository-name "$REPO_NAME" --region "$REGION" \
      --query 'lifecyclePolicyText' --output text)
    lc_status=$([[ -n "$LC" && "$LC" != "None" ]] && echo "policy=yes" || echo "policy=MISSING")
    row "ECR Repo: $REPO_NAME" "exists" "$IMG_COUNT images $lc_status"
  fi
done

# ══════════════════════════════════════════════════════════════════════════════
# Secrets Manager
# ══════════════════════════════════════════════════════════════════════════════
divider "Secrets Manager"

DELETED=$(aws_q secretsmanager describe-secret \
  --secret-id "${PROJECT}/${ENV}/app-secrets" --region "$REGION" \
  --query 'DeletedDate' --output text)
if [[ -z "$DELETED" || "$DELETED" == "NOT_FOUND" ]]; then
  row "Secret: ${PROJECT}/${ENV}/app-secrets" "MISSING"
elif [[ "$DELETED" == "None" ]]; then
  row "Secret: ${PROJECT}/${ENV}/app-secrets" "active"
else
  row "Secret: ${PROJECT}/${ENV}/app-secrets" "DELETING" "$DELETED"
fi

# ══════════════════════════════════════════════════════════════════════════════
# SSM Parameters
# ══════════════════════════════════════════════════════════════════════════════
divider "SSM Parameters"

for param in \
  "db/master_username" "db/master_password" \
  "db/app_username"    "db/app_password" \
  "app/secret_key"     "app/jwt_secret_key" \
  "monitoring/grafana_password"; do
  FOUND=$(aws_q ssm get-parameter \
    --name "/${PROJECT}/${ENV}/${param}" --region "$REGION" \
    --query 'Parameter.Name' --output text)
  [[ -n "$FOUND" && "$FOUND" != "None" ]] \
    && row "SSM: $param" "exists" \
    || row "SSM: $param" "MISSING"
done

# ══════════════════════════════════════════════════════════════════════════════
# Monitoring EC2
# ══════════════════════════════════════════════════════════════════════════════
divider "Monitoring EC2"

INSTANCE=$(aws_q ec2 describe-instances --region "$REGION" \
  --filters \
    "Name=tag:Project,Values=$PROJECT" \
    "Name=tag:Environment,Values=$ENV" \
    "Name=tag:Role,Values=monitoring" \
    "Name=instance-state-name,Values=running,pending,stopped,stopping" \
  --query 'Reservations[0].Instances[0].{id:InstanceId,ip:PublicIpAddress,state:State.Name,type:InstanceType}' \
  --output text)

if [[ -z "$INSTANCE" || "$INSTANCE" == "None"* ]]; then
  row "Monitoring EC2" "MISSING"
else
  read -r inst_id public_ip state itype <<< "$INSTANCE"
  row "Monitoring EC2: $inst_id" "$state" "$itype ${public_ip:-no-ip}"
  if [[ "$state" == "running" && -n "$public_ip" && "$public_ip" != "None" ]]; then
    printf "  ${DIM}       ├─ Grafana:    http://%s:3000${NC}\n" "$public_ip"
    printf "  ${DIM}       └─ Prometheus: http://%s:9090${NC}\n" "$public_ip"
  fi

  # EIP
  EIP=$(aws_q ec2 describe-addresses --region "$REGION" \
    --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Environment,Values=$ENV" \
    --query 'Addresses[0].PublicIp' --output text)
  [[ -n "$EIP" && "$EIP" != "None" ]] \
    && row "Elastic IP" "attached" "$EIP" \
    || row "Elastic IP" "MISSING"
fi

# ══════════════════════════════════════════════════════════════════════════════
# IAM Resources
# ══════════════════════════════════════════════════════════════════════════════
divider "IAM"

# Bootstrap resources
for role in \
  "${PROJECT}-github-actions-deploy" \
  "${PROJECT}-${ENV}-ecs-execution" \
  "${PROJECT}-${ENV}-ecs-task" \
  "${PROJECT}-${ENV}-vpc-flow-log" \
  "${PROJECT}-${ENV}-monitoring-ec2"; do
  STATUS=$(aws_q iam get-role --role-name "$role" \
    --query 'Role.RoleName' --output text)
  [[ -n "$STATUS" && "$STATUS" != "None" ]] \
    && row "IAM Role: $role" "exists" \
    || row "IAM Role: $role" "MISSING"
done

# Instance profile
IP=$(aws_q iam get-instance-profile \
  --instance-profile-name "${PROJECT}-${ENV}-monitoring" \
  --query 'InstanceProfile.InstanceProfileName' --output text)
[[ -n "$IP" && "$IP" != "None" ]] \
  && row "Instance Profile: ${PROJECT}-${ENV}-monitoring" "exists" \
  || row "Instance Profile: ${PROJECT}-${ENV}-monitoring" "MISSING"

# OIDC
OIDC=$(aws_q iam list-open-id-connect-providers \
  --query 'OpenIDConnectProviderList[?ends_with(Arn,`token.actions.githubusercontent.com`)].Arn' \
  --output text)
[[ -n "$OIDC" ]] \
  && row "OIDC Provider: GitHub Actions" "exists" \
  || row "OIDC Provider: GitHub Actions" "MISSING"

# ══════════════════════════════════════════════════════════════════════════════
# Bootstrap Infrastructure
# ══════════════════════════════════════════════════════════════════════════════
divider "Bootstrap Infrastructure"

# S3 state bucket
S3=$(aws_q s3api head-bucket --bucket "${PROJECT}-terraform-state" 2>/dev/null \
  && echo "exists" || echo "")
[[ -n "$S3" ]] \
  && row "S3: ${PROJECT}-terraform-state" "exists" \
  || row "S3: ${PROJECT}-terraform-state" "MISSING"

# Check state file exists
STATE=$(aws_q s3api head-object \
  --bucket "${PROJECT}-terraform-state" \
  --key "${ENV}/terraform.tfstate" \
  --query 'ContentLength' --output text)
[[ -n "$STATE" && "$STATE" != "None" ]] \
  && row "Terraform State: ${ENV}/terraform.tfstate" "exists" "${STATE} bytes" \
  || row "Terraform State: ${ENV}/terraform.tfstate" "MISSING" "fresh deploy needed"

# ══════════════════════════════════════════════════════════════════════════════
# S3 Monitoring Configs
# ══════════════════════════════════════════════════════════════════════════════
divider "S3 Monitoring Configs"

for cfg in prometheus.yml cloudwatch-exporter.yml grafana-datasources.yml \
           grafana-dashboards.yml nexusdeploy-dashboard.json; do
  FOUND=$(aws_q s3api head-object \
    --bucket "${PROJECT}-terraform-state" \
    --key "monitoring/config/${cfg}" \
    --query 'ContentLength' --output text)
  [[ -n "$FOUND" && "$FOUND" != "None" ]] \
    && row "S3 Config: $cfg" "exists" "${FOUND} bytes" \
    || row "S3 Config: $cfg" "MISSING"
done

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}$(printf '═%.0s' {1..80})${NC}"
printf "  ${BOLD}Summary:${NC}  "
printf "${GREEN}✅ %d OK${NC}  " "$OK"
printf "${YELLOW}⚠️  %d WARN${NC}  " "$WARN"
printf "${RED}❌ %d MISSING${NC}  " "$FAIL"
printf "${DIM}/ %d total${NC}\n" "$TOTAL"

if [[ "$FAIL" -gt 0 ]]; then
  echo -e "  ${RED}${BOLD}Not ready for deploy — fix ❌ items above first${NC}"
elif [[ "$WARN" -gt 0 ]]; then
  echo -e "  ${YELLOW}Review ⚠️  items — may indicate partial cleanup${NC}"
else
  echo -e "  ${GREEN}${BOLD}All resources healthy ✅${NC}"
fi
echo -e "${BOLD}$(printf '═%.0s' {1..80})${NC}"
echo ""