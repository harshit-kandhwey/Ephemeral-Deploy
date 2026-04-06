#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# NexusDeploy Resource Status Checker
# Lists all tagged resources and their current status across AWS services
#
# Usage:
#   bash scripts/check_resources.sh
#   bash scripts/check_resources.sh --env prod
#   bash scripts/check_resources.sh --region us-west-2
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
PROJECT="${PROJECT:-nexusdeploy}"
ENV="${ENV:-dev}"
REGION="${REGION:-us-east-1}"

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --env)     ENV="$2";    shift 2 ;;
    --region)  REGION="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✅ $*${NC}"; }
warn() { echo -e "  ${YELLOW}⚠️  $*${NC}"; }
bad()  { echo -e "  ${RED}❌ $*${NC}"; }
info() { echo -e "  ${CYAN}ℹ️  $*${NC}"; }
hdr()  { echo -e "\n${BOLD}${BLUE}── $* ──────────────────────────────────${NC}"; }

echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} NexusDeploy Resource Status Checker${NC}"
echo -e "${BOLD} Project: $PROJECT | Environment: $ENV | Region: $REGION${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"

TOTAL=0; RUNNING=0; STOPPED=0; MISSING=0

# ── ECS ───────────────────────────────────────────────────────────────────────
hdr "ECS"
CLUSTER="${PROJECT}-${ENV}"

CLUSTER_STATUS=$(aws ecs describe-clusters \
  --clusters "$CLUSTER" \
  --region "$REGION" \
  --query 'clusters[0].status' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$CLUSTER_STATUS" == "ACTIVE" ]]; then
  ok "Cluster: $CLUSTER ($CLUSTER_STATUS)"
  ((RUNNING++))
elif [[ "$CLUSTER_STATUS" == "NOT_FOUND" || "$CLUSTER_STATUS" == "None" ]]; then
  bad "Cluster: $CLUSTER — NOT FOUND"
  ((MISSING++))
else
  warn "Cluster: $CLUSTER ($CLUSTER_STATUS)"
  ((STOPPED++))
fi
((TOTAL++))

for svc in api worker beat; do
  SVC_NAME="${PROJECT}-${ENV}-${svc}"
  STATUS=$(aws ecs describe-services \
    --cluster "$CLUSTER" \
    --services "$SVC_NAME" \
    --region "$REGION" \
    --query 'services[0].{status:status,running:runningCount,desired:desiredCount,failed:deployments[0].failedTasks}' \
    --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$STATUS" == "NOT_FOUND" || -z "$STATUS" ]]; then
    bad "Service: $SVC_NAME — NOT FOUND"
    ((MISSING++))
  else
    read -r desired failed running svc_status <<< "$STATUS"
    if [[ "$svc_status" == "ACTIVE" && "${running:-0}" -eq "$desired" && "${running:-0}" -gt 0 ]]; then
      ok "Service: $SVC_NAME — $svc_status ($running/$desired running)"
      ((RUNNING++))
    elif [[ "$svc_status" == "DRAINING" || "${running:-0}" -eq 0 ]]; then
      warn "Service: $SVC_NAME — $svc_status ($running/$desired running, ${failed:-0} failed)"
      ((STOPPED++))
    else
      bad "Service: $SVC_NAME — $svc_status ($running/$desired running, ${failed:-0} failed)"
      ((STOPPED++))
    fi
  fi
  ((TOTAL++))
done

# ── RDS ───────────────────────────────────────────────────────────────────────
hdr "RDS"
DB_ID="${PROJECT}-${ENV}-postgres"
DB_STATUS=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_ID" \
  --region "$REGION" \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text 2>/dev/null || echo "NOT_FOUND")

((TOTAL++))
if [[ "$DB_STATUS" == "available" ]]; then
  ok "RDS: $DB_ID ($DB_STATUS)"
  ((RUNNING++))
elif [[ "$DB_STATUS" == "NOT_FOUND" ]]; then
  bad "RDS: $DB_ID — NOT FOUND"
  ((MISSING++))
else
  warn "RDS: $DB_ID ($DB_STATUS)"
  ((STOPPED++))
fi

# ── ElastiCache ───────────────────────────────────────────────────────────────
hdr "ElastiCache"
REDIS_ID="${PROJECT}-${ENV}-redis"
REDIS_STATUS=$(aws elasticache describe-cache-clusters \
  --cache-cluster-id "$REDIS_ID" \
  --region "$REGION" \
  --query 'CacheClusters[0].CacheClusterStatus' \
  --output text 2>/dev/null || echo "NOT_FOUND")

((TOTAL++))
if [[ "$REDIS_STATUS" == "available" ]]; then
  ok "Redis: $REDIS_ID ($REDIS_STATUS)"
  ((RUNNING++))
elif [[ "$REDIS_STATUS" == "NOT_FOUND" ]]; then
  bad "Redis: $REDIS_ID — NOT FOUND"
  ((MISSING++))
else
  warn "Redis: $REDIS_ID ($REDIS_STATUS)"
  ((STOPPED++))
fi

# ── VPC & Networking ──────────────────────────────────────────────────────────
hdr "VPC & Networking"
VPC_ID=$(aws ec2 describe-vpcs \
  --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Environment,Values=$ENV" \
  --query 'Vpcs[0].VpcId' \
  --output text 2>/dev/null || echo "None")

((TOTAL++))
if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
  bad "VPC — NOT FOUND"
  ((MISSING++))
else
  ok "VPC: $VPC_ID"
  ((RUNNING++))

  # VPC Endpoints
  ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'VpcEndpoints[?State!=`deleted`].{id:VpcEndpointId,svc:ServiceName,state:State}' \
    --output text 2>/dev/null || echo "")

  if [[ -z "$ENDPOINTS" ]]; then
    bad "VPC Endpoints — NONE FOUND (ECS tasks cannot reach AWS APIs)"
  else
    ENDPOINT_COUNT=$(echo "$ENDPOINTS" | wc -l)
    ok "VPC Endpoints: $ENDPOINT_COUNT active"
    while IFS=$'\t' read -r ep_id svc state; do
      SHORT_SVC=$(echo "$svc" | sed "s/com.amazonaws.${REGION}\.//")
      if [[ "$state" == "available" ]]; then
        info "  $SHORT_SVC ($ep_id) — $state"
      else
        warn "  $SHORT_SVC ($ep_id) — $state"
      fi
    done <<< "$ENDPOINTS"
  fi

  # NAT Gateway
  NAT=$(aws ec2 describe-nat-gateways \
    --region "$REGION" \
    --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" \
    --query 'NatGateways[0].NatGatewayId' \
    --output text 2>/dev/null || echo "None")
  if [[ "$NAT" != "None" && -n "$NAT" ]]; then
    info "NAT Gateway: $NAT (active — ~\$1/day cost)"
  fi
fi

# ── ECR ───────────────────────────────────────────────────────────────────────
hdr "ECR"
for repo in api worker; do
  REPO_NAME="${PROJECT}-${repo}-${ENV}"
  IMAGE_COUNT=$(aws ecr describe-images \
    --repository-name "$REPO_NAME" \
    --region "$REGION" \
    --query 'length(imageDetails)' \
    --output text 2>/dev/null || echo "NOT_FOUND")

  ((TOTAL++))
  if [[ "$IMAGE_COUNT" == "NOT_FOUND" ]]; then
    bad "ECR: $REPO_NAME — NOT FOUND"
    ((MISSING++))
  else
    ok "ECR: $REPO_NAME — $IMAGE_COUNT image(s)"
    ((RUNNING++))
  fi
done

# ── Monitoring EC2 ────────────────────────────────────────────────────────────
hdr "Monitoring EC2"
INSTANCE=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters \
    "Name=tag:Project,Values=$PROJECT" \
    "Name=tag:Environment,Values=$ENV" \
    "Name=instance-state-name,Values=running,stopped,pending" \
  --query 'Reservations[0].Instances[0].{id:InstanceId,state:State.Name,ip:PublicIpAddress}' \
  --output text 2>/dev/null || echo "None")

((TOTAL++))
if [[ "$INSTANCE" == "None" || -z "$INSTANCE" ]]; then
  bad "Monitoring EC2 — NOT FOUND"
  ((MISSING++))
else
  read -r inst_id public_ip state <<< "$INSTANCE"
  if [[ "$state" == "running" ]]; then
    ok "Monitoring EC2: $inst_id ($state) — http://${public_ip}:3000"
    ((RUNNING++))
  else
    warn "Monitoring EC2: $inst_id ($state)"
    ((STOPPED++))
  fi
fi

# ── Secrets Manager ───────────────────────────────────────────────────────────
hdr "Secrets Manager"
DELETED=$(aws secretsmanager describe-secret \
  --secret-id "${PROJECT}/${ENV}/app-secrets" \
  --region "$REGION" \
  --query 'DeletedDate' \
  --output text 2>/dev/null || echo "NOT_FOUND")

((TOTAL++))
if [[ "$DELETED" == "NOT_FOUND" ]]; then
  bad "App secret — NOT FOUND"
  ((MISSING++))
elif [[ "$DELETED" == "None" ]]; then
  ok "App secret — active"
  ((RUNNING++))
else
  warn "App secret — scheduled for deletion ($DELETED)"
  ((STOPPED++))
fi

# ── SSM Parameters ────────────────────────────────────────────────────────────
hdr "SSM Parameters"
PARAMS=(
  "db/master_username" "db/master_password"
  "db/app_username"    "db/app_password"
  "app/secret_key"     "app/jwt_secret_key"
  "monitoring/grafana_password"
)
for param in "${PARAMS[@]}"; do
  PARAM_PATH="/${PROJECT}/${ENV}/${param}"
  EXISTS=$(aws ssm get-parameter \
    --name "$PARAM_PATH" \
    --region "$REGION" \
    --query 'Parameter.Name' \
    --output text 2>/dev/null || echo "NOT_FOUND")

  ((TOTAL++))
  if [[ "$EXISTS" == "NOT_FOUND" ]]; then
    bad "SSM: $PARAM_PATH — NOT FOUND"
    ((MISSING++))
  else
    ok "SSM: $PARAM_PATH"
    ((RUNNING++))
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Summary${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "  Total checked : $TOTAL"
echo -e "  ${GREEN}Healthy/Found : $RUNNING${NC}"
echo -e "  ${YELLOW}Degraded      : $STOPPED${NC}"
echo -e "  ${RED}Missing       : $MISSING${NC}"

if [[ $MISSING -eq 0 && $STOPPED -eq 0 ]]; then
  echo -e "\n  ${GREEN}${BOLD}✅ All resources healthy — ready for deploy${NC}"
elif [[ $MISSING -gt 0 ]]; then
  echo -e "\n  ${RED}${BOLD}❌ Missing resources — run deploy to create them${NC}"
else
  echo -e "\n  ${YELLOW}${BOLD}⚠️  Some resources degraded — check above${NC}"
fi
echo ""