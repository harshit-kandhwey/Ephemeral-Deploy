#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# NexusDeploy Resource Status Checker — Parallel execution
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

# Temp dir for parallel results
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

# ── Parallel check functions ──────────────────────────────────────────────────
# Each writes a result file: "<order>|<name>|<status>|<detail>"

q() { aws "$@" 2>/dev/null; }

check_ecs_cluster() {
  local out status detail
  out=$(q ecs describe-clusters --clusters "${PROJECT}-${ENV}" --region "$REGION" \
    --query 'clusters[0].{p:pendingTasksCount,r:runningTasksCount,s:status,v:activeServicesCount}' \
    --output text)
  if [[ -z "$out" ]]; then
    echo "01|Cluster: ${PROJECT}-${ENV}|MISSING|"
  else
    read -r pending running status svcs <<< "$out"
    echo "01|Cluster: ${PROJECT}-${ENV}|${status}|services=$svcs running=$running pending=$pending"
  fi
}

check_ecs_services() {
  local i=2
  for svc in api worker beat; do
    local name="${PROJECT}-${ENV}-${svc}"
    local out=$(q ecs describe-services \
      --cluster "${PROJECT}-${ENV}" --services "$name" --region "$REGION" \
      --query 'services[0].{d:desiredCount,f:deployments[0].failedTasks,r:runningCount,s:status}' \
      --output text)
    if [[ -z "$out" || "$out" == "None"* ]]; then
      echo "0${i}|Service: $name|MISSING|"
    else
      read -r desired failed running svc_status <<< "$out"
      local detail="running=${running:-0}/${desired:-0} failed=${failed:-0}"
      if [[ "$svc_status" == "ACTIVE" && "${running:-0}" -eq "${desired:-1}" && "${running:-0}" -gt 0 ]]; then
        echo "0${i}|Service: $name|RUNNING|$detail"
      else
        echo "0${i}|Service: $name|${svc_status:-MISSING}|$detail"
      fi
    fi
    ((i++))
  done
}

check_task_defs() {
  local i=5
  for svc in api worker beat; do
    local out=$(q ecs describe-task-definition \
      --task-definition "${PROJECT}-${ENV}-${svc}" --region "$REGION" \
      --query 'taskDefinition.{r:revision,s:status}' --output text)
    if [[ -z "$out" ]]; then
      echo "0${i}|Task Def: ${PROJECT}-${ENV}-${svc}|MISSING|"
    else
      read -r rev status <<< "$out"
      echo "0${i}|Task Def: ${PROJECT}-${ENV}-${svc}|${status}|revision=$rev"
    fi
    ((i++))
  done
}

check_log_groups() {
  local i=10
  for lg in \
    "/ecs/${PROJECT}/${ENV}/api" \
    "/ecs/${PROJECT}/${ENV}/worker" \
    "/ecs/${PROJECT}/${ENV}/beat" \
    "/aws/vpc/flowlogs/${PROJECT}-${ENV}"; do
    local found=$(q logs describe-log-groups \
      --log-group-name-prefix "$lg" --region "$REGION" \
      --query 'logGroups[0].logGroupName' --output text)
    if [[ -n "$found" && "$found" != "None" ]]; then
      echo "${i}|Log Group: $lg|exists|"
    else
      echo "${i}|Log Group: $lg|MISSING|"
    fi
    ((i++))
  done
}

check_alarms() {
  local i=20
  for alarm in \
    "${PROJECT}-${ENV}-api-cpu-high" \
    "${PROJECT}-${ENV}-rds-cpu-high" \
    "${PROJECT}-${ENV}-redis-memory-high"; do
    local state=$(q cloudwatch describe-alarms \
      --alarm-names "$alarm" --region "$REGION" \
      --query 'MetricAlarms[0].StateValue' --output text)
    if [[ -z "$state" || "$state" == "None" ]]; then
      echo "${i}|Alarm: $alarm|MISSING|"
    else
      echo "${i}|Alarm: $alarm|${state}|"
    fi
    ((i++))
  done
}

check_dashboard() {
  local dash=$(q cloudwatch get-dashboard \
    --dashboard-name "${PROJECT}-${ENV}" --region "$REGION" \
    --query 'DashboardName' --output text)
  if [[ -n "$dash" && "$dash" != "None" ]]; then
    echo "25|Dashboard: ${PROJECT}-${ENV}|exists|"
  else
    echo "25|Dashboard: ${PROJECT}-${ENV}|MISSING|"
  fi
}

check_rds() {
  local out=$(q rds describe-db-instances \
    --db-instance-identifier "${PROJECT}-${ENV}-postgres" --region "$REGION" \
    --query 'DBInstances[0].{c:DBInstanceClass,e:EngineVersion,s:DBInstanceStatus}' \
    --output text)
  if [[ -z "$out" ]]; then
    echo "30|RDS: ${PROJECT}-${ENV}-postgres|MISSING|"
  else
    read -r class engine status <<< "$out"
    echo "30|RDS: ${PROJECT}-${ENV}-postgres|${status}|pg=$engine $class"
  fi

  local pg=$(q rds describe-db-parameter-groups \
    --db-parameter-group-name "${PROJECT}-${ENV}-pg15" --region "$REGION" \
    --query 'DBParameterGroups[0].DBParameterGroupName' --output text)
  [[ -n "$pg" && "$pg" != "None" ]] \
    && echo "31|RDS param group: ${PROJECT}-${ENV}-pg15|exists|" \
    || echo "31|RDS param group: ${PROJECT}-${ENV}-pg15|MISSING|"

  local sg=$(q rds describe-db-subnet-groups \
    --db-subnet-group-name "${PROJECT}-${ENV}-db-subnet" --region "$REGION" \
    --query 'DBSubnetGroups[0].SubnetGroupStatus' --output text)
  [[ -n "$sg" && "$sg" != "None" ]] \
    && echo "32|RDS subnet group: ${PROJECT}-${ENV}-db-subnet|${sg}|" \
    || echo "32|RDS subnet group: ${PROJECT}-${ENV}-db-subnet|MISSING|"
}

check_elasticache() {
  local out=$(q elasticache describe-cache-clusters \
    --cache-cluster-id "${PROJECT}-${ENV}-redis" --region "$REGION" \
    --query 'CacheClusters[0].{e:EngineVersion,s:CacheClusterStatus,t:CacheNodeType}' \
    --output text)
  if [[ -z "$out" ]]; then
    echo "35|Redis: ${PROJECT}-${ENV}-redis|MISSING|"
  else
    read -r engine status node_type <<< "$out"
    echo "35|Redis: ${PROJECT}-${ENV}-redis|${status}|redis=$engine $node_type"
  fi

  local csg=$(q elasticache describe-cache-subnet-groups \
    --cache-subnet-group-name "${PROJECT}-${ENV}-cache-subnet" --region "$REGION" \
    --query 'CacheSubnetGroups[0].CacheSubnetGroupName' --output text)
  [[ -n "$csg" && "$csg" != "None" ]] \
    && echo "36|Cache subnet group: ${PROJECT}-${ENV}-cache-subnet|exists|" \
    || echo "36|Cache subnet group: ${PROJECT}-${ENV}-cache-subnet|MISSING|"
}

check_vpc() {
  local vpc_id=$(q ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Environment,Values=$ENV" \
    --query 'Vpcs[0].VpcId' --output text)

  if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
    echo "40|VPC: ${PROJECT}-${ENV}|MISSING|"
    for r in IGW Subnets "Route Tables" "Flow Log" Endpoints "Security Groups"; do
      echo "41|$r|MISSING|no VPC"
    done
    return
  fi

  echo "40|VPC: ${PROJECT}-${ENV}|exists|$vpc_id"

  local igw=$(q ec2 describe-internet-gateways --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=$vpc_id" \
    --query 'InternetGateways[0].InternetGatewayId' --output text)
  [[ -n "$igw" && "$igw" != "None" ]] \
    && echo "41|Internet Gateway|attached|$igw" \
    || echo "41|Internet Gateway|MISSING|"

  local sn=$(q ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=$vpc_id" \
    --query 'length(Subnets)' --output text)
  [[ "${sn:-0}" -gt 0 ]] \
    && echo "42|Subnets|exists|${sn} total" \
    || echo "42|Subnets|MISSING|"

  local rt=$(q ec2 describe-route-tables --region "$REGION" \
    --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:Project,Values=$PROJECT" \
    --query 'length(RouteTables)' --output text)
  [[ "${rt:-0}" -gt 0 ]] \
    && echo "43|Route Tables|exists|${rt} tables" \
    || echo "43|Route Tables|MISSING|"

  local fl=$(q ec2 describe-flow-logs --region "$REGION" \
    --filter "Name=resource-id,Values=$vpc_id" \
    --query 'FlowLogs[0].FlowLogStatus' --output text)
  [[ -n "$fl" && "$fl" != "None" ]] \
    && echo "44|VPC Flow Log|${fl}|" \
    || echo "44|VPC Flow Log|MISSING|"

  local ep_count=$(q ec2 describe-vpc-endpoints --region "$REGION" \
    --filters "Name=vpc-id,Values=$vpc_id" \
    --query 'length(VpcEndpoints[?State!=`deleted`])' --output text)
  [[ "${ep_count:-0}" -gt 0 ]] \
    && echo "45|VPC Endpoints|exists|${ep_count} endpoints" \
    || echo "45|VPC Endpoints|MISSING|ECS tasks cannot reach AWS APIs"

  local sg=$(q ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:Project,Values=$PROJECT" \
    --query 'length(SecurityGroups)' --output text)
  [[ "${sg:-0}" -gt 0 ]] \
    && echo "46|Security Groups|exists|${sg} groups" \
    || echo "46|Security Groups|MISSING|"
}

check_ecr() {
  for repo in api worker; do
    local name="${PROJECT}-${repo}-${ENV}"
    local cnt=$(q ecr describe-images --repository-name "$name" --region "$REGION" \
      --query 'length(imageDetails)' --output text)
    if [[ -z "$cnt" ]]; then
      echo "50|ECR: $name|MISSING|"
    else
      local lc=$(q ecr get-lifecycle-policy --repository-name "$name" --region "$REGION" \
        --query 'lifecyclePolicyText' --output text)
      local lc_s=$([[ -n "$lc" && "$lc" != "None" ]] && echo "policy=yes" || echo "policy=MISSING")
      echo "50|ECR: $name|exists|$cnt images $lc_s"
    fi
  done
}

check_secret() {
  local del=$(q secretsmanager describe-secret \
    --secret-id "${PROJECT}/${ENV}/app-secrets" --region "$REGION" \
    --query 'DeletedDate' --output text)
  if [[ -z "$del" ]]; then
    echo "55|Secret: ${PROJECT}/${ENV}/app-secrets|MISSING|"
  elif [[ "$del" == "None" ]]; then
    echo "55|Secret: ${PROJECT}/${ENV}/app-secrets|active|"
  else
    echo "55|Secret: ${PROJECT}/${ENV}/app-secrets|DELETING|$del"
  fi
}

check_ssm() {
  local i=60
  for param in db/master_username db/master_password db/app_username db/app_password \
               app/secret_key app/jwt_secret_key monitoring/grafana_password; do
    local found=$(q ssm get-parameter \
      --name "/${PROJECT}/${ENV}/${param}" --region "$REGION" \
      --query 'Parameter.Name' --output text)
    [[ -n "$found" && "$found" != "None" ]] \
      && echo "${i}|SSM: $param|exists|" \
      || echo "${i}|SSM: $param|MISSING|"
    ((i++))
  done
}

check_ec2() {
  local out=$(q ec2 describe-instances --region "$REGION" \
    --filters \
      "Name=tag:Project,Values=$PROJECT" \
      "Name=tag:Environment,Values=$ENV" \
      "Name=tag:Role,Values=monitoring" \
      "Name=instance-state-name,Values=running,pending,stopped,stopping" \
    --query 'Reservations[0].Instances[0].{id:InstanceId,ip:PublicIpAddress,state:State.Name,type:InstanceType}' \
    --output text)
  if [[ -z "$out" || "$out" == "None"* ]]; then
    echo "70|Monitoring EC2|MISSING|"
  else
    read -r inst_id public_ip state itype <<< "$out"
    echo "70|Monitoring EC2: $inst_id|${state}|$itype ${public_ip:-no-ip}"
    if [[ "$state" == "running" && -n "$public_ip" && "$public_ip" != "None" ]]; then
      echo "71|  Grafana|http://${public_ip}:3000|"
      echo "72|  Prometheus|http://${public_ip}:9090|"
    fi
  fi

  local eip=$(q ec2 describe-addresses --region "$REGION" \
    --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Environment,Values=$ENV" \
    --query 'Addresses[0].PublicIp' --output text)
  [[ -n "$eip" && "$eip" != "None" ]] \
    && echo "73|Elastic IP|attached|$eip" \
    || echo "73|Elastic IP|MISSING|"
}

check_iam() {
  local i=80
  for role in \
    "${PROJECT}-github-actions-deploy" \
    "${PROJECT}-${ENV}-ecs-execution" \
    "${PROJECT}-${ENV}-ecs-task" \
    "${PROJECT}-${ENV}-vpc-flow-log" \
    "${PROJECT}-${ENV}-monitoring-ec2"; do
    local s=$(q iam get-role --role-name "$role" \
      --query 'Role.RoleName' --output text)
    [[ -n "$s" && "$s" != "None" ]] \
      && echo "${i}|IAM Role: $role|exists|" \
      || echo "${i}|IAM Role: $role|MISSING|"
    ((i++))
  done

  local ip=$(q iam get-instance-profile \
    --instance-profile-name "${PROJECT}-${ENV}-monitoring" \
    --query 'InstanceProfile.InstanceProfileName' --output text)
  [[ -n "$ip" && "$ip" != "None" ]] \
    && echo "86|Instance Profile: ${PROJECT}-${ENV}-monitoring|exists|" \
    || echo "86|Instance Profile: ${PROJECT}-${ENV}-monitoring|MISSING|"

  local oidc=$(q iam list-open-id-connect-providers \
    --query 'OpenIDConnectProviderList[?ends_with(Arn,`token.actions.githubusercontent.com`)].Arn' \
    --output text)
  [[ -n "$oidc" ]] \
    && echo "87|OIDC Provider: GitHub Actions|exists|" \
    || echo "87|OIDC Provider: GitHub Actions|MISSING|"
}

check_bootstrap() {
  local s3=$(aws s3api head-bucket --bucket "${PROJECT}-terraform-state" \
    --region "$REGION" &>/dev/null && echo "exists" || echo "")
  [[ -n "$s3" ]] \
    && echo "90|S3: ${PROJECT}-terraform-state|exists|" \
    || echo "90|S3: ${PROJECT}-terraform-state|MISSING|"

  local state=$(q s3api head-object \
    --bucket "${PROJECT}-terraform-state" --key "${ENV}/terraform.tfstate" \
    --query 'ContentLength' --output text)
  [[ -n "$state" && "$state" != "None" ]] \
    && echo "91|Terraform State: ${ENV}/terraform.tfstate|exists|${state} bytes" \
    || echo "91|Terraform State: ${ENV}/terraform.tfstate|MISSING|fresh deploy needed"
}

check_s3_configs() {
  local i=95
  for cfg in prometheus.yml cloudwatch-exporter.yml grafana-datasources.yml \
             grafana-dashboards.yml nexusdeploy-dashboard.json; do
    local sz=$(q s3api head-object \
      --bucket "${PROJECT}-terraform-state" \
      --key "monitoring/config/${cfg}" \
      --query 'ContentLength' --output text)
    [[ -n "$sz" && "$sz" != "None" ]] \
      && echo "${i}|S3 Config: $cfg|exists|${sz} bytes" \
      || echo "${i}|S3 Config: $cfg|MISSING|"
    ((i++))
  done
}


# ── Launch all checks in parallel ────────────────────────────────────────────
check_ecs_cluster > "$WORK_DIR/ecs_cluster" &
check_ecs_services > "$WORK_DIR/ecs_services" &
check_task_defs > "$WORK_DIR/task_defs" &
check_log_groups > "$WORK_DIR/log_groups" &
check_alarms > "$WORK_DIR/alarms" &
check_dashboard > "$WORK_DIR/dashboard" &
check_rds > "$WORK_DIR/rds" &
check_elasticache > "$WORK_DIR/elasticache" &
check_vpc > "$WORK_DIR/vpc" &
check_ecr > "$WORK_DIR/ecr" &
check_secret > "$WORK_DIR/secret" &
check_ssm > "$WORK_DIR/ssm" &
check_ec2 > "$WORK_DIR/ec2" &
check_iam > "$WORK_DIR/iam" &
check_bootstrap > "$WORK_DIR/bootstrap" &
check_s3_configs > "$WORK_DIR/s3_configs" &

# ── Wait for all background jobs ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}$(printf '=%.0s' {1..80})${NC}"
echo -e "${BOLD}  NexusDeploy Resource Status — $PROJECT/$ENV ($REGION)${NC}"
echo -e "${BOLD}$(printf '=%.0s' {1..80})${NC}"
echo -e "  ${DIM}Running checks in parallel...${NC}"

wait  # Wait for all background jobs

# ── Render results ────────────────────────────────────────────────────────────
TOTAL=0; OK=0; WARN=0; FAIL=0

row() {
  local name="$1" status="$2" detail="${3:-}"
  local color icon
  ((TOTAL++))
  case "$status" in
    OK|active|available|exists|ACTIVE|RUNNING|Complete|attached|enabled|ACTIVE_FLOW_LOGGING)
      color="$GREEN"; icon="✅"; ((OK++)) ;;
    MISSING|NOT_FOUND|INACTIVE|deleted)
      color="$RED";   icon="❌"; ((FAIL++)) ;;
    http*)
      color="$CYAN";  icon="  "; ((OK++)) ;;  # URL lines
    *)
      color="$YELLOW"; icon="⚠️ "; ((WARN++)) ;;
  esac
  printf "  ${icon}  %-48s ${color}%-20s${NC} ${DIM}%s${NC}\n" "$name" "$status" "$detail"
}

divider() { echo -e "\n${BOLD}${CYAN}  ▸ $*${NC}"; printf "  %s\n" "$(printf '─%.0s' {1..78})"; }

# Section headers mapped to order ranges
declare -A SECTIONS=(
  ["01"]="ECS" ["05"]="ECS" ["10"]="CloudWatch Log Groups"
  ["20"]="CloudWatch Alarms" ["25"]="CloudWatch Dashboard"
  ["30"]="RDS" ["35"]="ElastiCache" ["40"]="VPC & Networking"
  ["50"]="ECR" ["55"]="Secrets Manager" ["60"]="SSM Parameters"
  ["70"]="Monitoring EC2" ["80"]="IAM" ["90"]="Bootstrap" ["95"]="S3 Monitoring Configs"
)

LAST_SECTION=""
printf "\n  %-4s  %-48s %-20s %s\n" "" "Resource" "Status" "Detail"
printf "  %s\n" "$(printf '─%.0s' {1..78})"

# Collect and sort all results
ALL_RESULTS=$(cat "$WORK_DIR"/* 2>/dev/null | sort -t'|' -k1,1n)

while IFS='|' read -r order name status detail; do
  [[ -z "$order" ]] && continue
  # Determine section
  prefix="${order:0:2}"
  section="${SECTIONS[$prefix]:-}"
  if [[ -n "$section" && "$section" != "$LAST_SECTION" ]]; then
    divider "$section"
    LAST_SECTION="$section"
  fi
  row "$name" "$status" "$detail"
done <<< "$ALL_RESULTS"

# ── Summary / Prerequisites check ────────────────────────────────────────────
PREREQ_FAIL=$(
  {
    aws ecr describe-repositories --repository-names "${PROJECT}-api-${ENV}" --region "$REGION" &>/dev/null || echo "FAIL"
    aws ecr describe-repositories --repository-names "${PROJECT}-worker-${ENV}" --region "$REGION" &>/dev/null || echo "FAIL"
    for param in db/master_username db/master_password db/app_username db/app_password \
                 app/secret_key app/jwt_secret_key monitoring/grafana_password; do
      aws ssm get-parameter --name "/${PROJECT}/${ENV}/${param}" --region "$REGION" &>/dev/null || echo "FAIL"
    done
    aws iam get-role --role-name "${PROJECT}-github-actions-deploy" &>/dev/null || echo "FAIL"
    aws s3api head-bucket --bucket "${PROJECT}-terraform-state" --region "$REGION" &>/dev/null || echo "FAIL"
  } | grep -c "FAIL" || echo 0
)

echo ""
echo -e "${BOLD}$(printf '=%.0s' {1..80})${NC}"
printf "  ${BOLD}Counts:${NC}  ${GREEN}%d exist${NC}  ${YELLOW}%d warn${NC}  ${RED}%d missing${NC}  ${DIM}/ %d checked${NC}\n" \
  "$OK" "$WARN" "$FAIL" "$TOTAL"
echo ""

PREREQ_FAIL=$(echo "$PREREQ_FAIL" | tr -d '[:space:]')
PREREQ_FAIL="${PREREQ_FAIL:-0}"
if [[ "$PREREQ_FAIL" -gt 0 ]]; then
  echo -e "  ${RED}${BOLD}Prerequisites missing ($PREREQ_FAIL) — run bootstrap.sh before deploying${NC}"
else
  CLUSTER_UP=$(aws ecs describe-clusters --clusters "${PROJECT}-${ENV}" --region "$REGION" \
    --query 'clusters[0].status' --output text 2>/dev/null || echo "")
  if [[ "$CLUSTER_UP" == "ACTIVE" ]]; then
    echo -e "  ${GREEN}${BOLD}Infrastructure is UP${NC}"
  else
    echo -e "  ${GREEN}${BOLD}Prerequisites met — safe to deploy${NC}"
    echo -e "  ${DIM}   Missing resources will be created by Terraform${NC}"
  fi
fi
echo -e "${BOLD}$(printf '=%.0s' {1..80})${NC}"
echo ""