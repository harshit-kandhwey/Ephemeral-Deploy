#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# cleanup.sh - Tag-based resource cleanup fallback
#
# When Terraform destroy fails, this script hunts down every AWS resource
# tagged with Project=nexusdeploy + Environment=<env> and deletes them.
#
# Usage:
#   ./scripts/cleanup.sh --env dev --region us-east-1 [--force] [--dry-run]
#
# The script cleans up in dependency order:
#   ECS Services → ECS Tasks → ECS Cluster → ECR Images
#   → RDS → ElastiCache → Security Groups → NAT GW → Subnets
#   → Route Tables → Internet GW → VPC → Secrets Manager
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Parse arguments ───────────────────────────
ENV=""
REGION="us-east-1"
FORCE=false
DRY_RUN=false
PROJECT="nexusdeploy"

while [[ $# -gt 0 ]]; do
  case $1 in
    --env)      ENV="$2"; shift 2 ;;
    --region)   REGION="$2"; shift 2 ;;
    --project)  PROJECT="$2"; shift 2 ;;
    --force)    FORCE=true; shift ;;
    --dry-run)  DRY_RUN=true; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

[[ -z "$ENV" ]] && { echo "Usage: $0 --env <dev|staging> --region <region>"; exit 1; }
[[ "$ENV" == "prod" && "$FORCE" != "true" ]] && {
  echo "❌ Production cleanup requires --force flag. Refusing."
  exit 1
}

# ── Colors & helpers ──────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_delete()  { echo -e "${RED}[DEL]${NC}   $1"; }

# Wrapper: execute or just print in dry-run
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} Would run: $*"
  else
    eval "$@"
  fi
}

TAG_KEY="Project"
TAG_VAL="$PROJECT"
ENV_KEY="Environment"
ENV_VAL="$ENV"

echo ""
echo "════════════════════════════════════════════════════════"
echo " NexusDeploy Cleanup Script"
echo " Project: $PROJECT | Environment: $ENV | Region: $REGION"
[[ "$DRY_RUN" == "true" ]] && echo " MODE: DRY RUN (no changes will be made)"
echo "════════════════════════════════════════════════════════"
echo ""

# ── Helper: Get resources by tags ────────────
get_resources_by_tag() {
  local resource_type=$1
  aws resourcegroupstaggingapi get-resources \
    --tag-filters "Key=$TAG_KEY,Values=$TAG_VAL" "Key=$ENV_KEY,Values=$ENV_VAL" \
    --resource-type-filters "$resource_type" \
    --region "$REGION" \
    --query 'ResourceTagMappingList[].ResourceARN' \
    --output text 2>/dev/null || echo ""
}

ERRORS=0

# ─────────────────────────────────────────────
# STEP 1: Scale down ECS services (graceful)
# ─────────────────────────────────────────────
log_info "Step 1/10: Scaling down ECS services..."

CLUSTER_ARN=$(get_resources_by_tag "ecs:cluster" | head -1)
if [[ -n "$CLUSTER_ARN" ]]; then
  CLUSTER_NAME=$(echo "$CLUSTER_ARN" | awk -F'/' '{print $NF}')
  log_info "Found cluster: $CLUSTER_NAME"

  SERVICES=$(aws ecs list-services \
    --cluster "$CLUSTER_NAME" \
    --region "$REGION" \
    --query 'serviceArns[]' \
    --output text 2>/dev/null || echo "")

  for svc in $SERVICES; do
    log_delete "Scaling down service: $svc"
    run aws ecs update-service \
      --cluster "$CLUSTER_NAME" \
      --service "$svc" \
      --desired-count 0 \
      --region "$REGION" \
      --output none

    run aws ecs delete-service \
      --cluster "$CLUSTER_NAME" \
      --service "$svc" \
      --force \
      --region "$REGION" \
      --output none
  done

  # Wait for tasks to drain
  log_info "Waiting for ECS tasks to drain (max 60s)..."
  [[ "$DRY_RUN" != "true" ]] && sleep 30 || true

  log_delete "Deleting ECS cluster: $CLUSTER_NAME"
  run aws ecs delete-cluster \
    --cluster "$CLUSTER_NAME" \
    --region "$REGION" \
    --output none

  log_success "ECS cluster cleaned up"
else
  log_warn "No ECS cluster found for $PROJECT/$ENV"
fi

# ─────────────────────────────────────────────
# STEP 2: Delete ECR images and repositories
# ─────────────────────────────────────────────
log_info "Step 2/10: Cleaning ECR repositories..."

for repo_suffix in "api" "worker"; do
  REPO_NAME="${PROJECT}-${repo_suffix}-${ENV}"
  
  if aws ecr describe-repositories --repository-names "$REPO_NAME" --region "$REGION" 2>/dev/null; then
    # Delete all images first
    IMAGE_IDS=$(aws ecr list-images \
      --repository-name "$REPO_NAME" \
      --region "$REGION" \
      --query 'imageIds[*]' \
      --output json)

    if [[ "$IMAGE_IDS" != "[]" && -n "$IMAGE_IDS" ]]; then
      log_delete "Deleting images from $REPO_NAME..."
      run aws ecr batch-delete-image \
        --repository-name "$REPO_NAME" \
        --image-ids "$IMAGE_IDS" \
        --region "$REGION" \
        --output none
    fi

    log_delete "Deleting ECR repository: $REPO_NAME"
    run aws ecr delete-repository \
      --repository-name "$REPO_NAME" \
      --region "$REGION" \
      --output none
    log_success "Deleted ECR: $REPO_NAME"
  else
    log_warn "ECR repository $REPO_NAME not found"
  fi
done

# ─────────────────────────────────────────────
# STEP 3: Delete RDS instance
# ─────────────────────────────────────────────
log_info "Step 3/10: Deleting RDS instances..."

DB_IDENTIFIER="${PROJECT}-${ENV}-postgres"
if aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$REGION" 2>/dev/null; then

  log_delete "Deleting RDS: $DB_IDENTIFIER (no final snapshot)"
  run aws rds delete-db-instance \
    --db-instance-identifier "$DB_IDENTIFIER" \
    --skip-final-snapshot \
    --region "$REGION" \
    --output none

  log_info "Waiting for RDS deletion (this takes a few minutes)..."
  [[ "$DRY_RUN" != "true" ]] && \
    aws rds wait db-instance-deleted \
      --db-instance-identifier "$DB_IDENTIFIER" \
      --region "$REGION" || true

  log_success "RDS instance deleted"
else
  log_warn "RDS instance $DB_IDENTIFIER not found"
fi

# ─────────────────────────────────────────────
# STEP 4: Delete ElastiCache
# ─────────────────────────────────────────────
log_info "Step 4/10: Deleting ElastiCache clusters..."

CACHE_ID="${PROJECT}-${ENV}-redis"
if aws elasticache describe-cache-clusters \
  --cache-cluster-id "$CACHE_ID" \
  --region "$REGION" 2>/dev/null; then

  log_delete "Deleting ElastiCache: $CACHE_ID"
  run aws elasticache delete-cache-cluster \
    --cache-cluster-id "$CACHE_ID" \
    --region "$REGION" \
    --output none

  [[ "$DRY_RUN" != "true" ]] && \
    aws elasticache wait cache-cluster-deleted \
      --cache-cluster-id "$CACHE_ID" \
      --region "$REGION" || true

  log_success "ElastiCache deleted"
else
  log_warn "ElastiCache $CACHE_ID not found"
fi

# ─────────────────────────────────────────────
# STEP 5: Delete Secrets Manager secrets
# ─────────────────────────────────────────────
log_info "Step 5/10: Deleting Secrets Manager secrets..."

SECRETS=$(aws secretsmanager list-secrets \
  --region "$REGION" \
  --filter Key=name,Values="${PROJECT}/${ENV}/" \
  --query 'SecretList[].ARN' \
  --output text 2>/dev/null || echo "")

for secret_arn in $SECRETS; do
  log_delete "Deleting secret: $secret_arn"
  run aws secretsmanager delete-secret \
    --secret-id "$secret_arn" \
    --force-delete-without-recovery \
    --region "$REGION" \
    --output none
done
log_success "Secrets cleaned up"

# ─────────────────────────────────────────────
# STEP 6: Find and cleanup VPC resources
# ─────────────────────────────────────────────
log_info "Step 6/10: Cleaning up VPC resources..."

VPC_ID=$(aws ec2 describe-vpcs \
  --region "$REGION" \
  --filters \
    "Name=tag:Project,Values=$TAG_VAL" \
    "Name=tag:Environment,Values=$ENV_VAL" \
  --query 'Vpcs[0].VpcId' \
  --output text 2>/dev/null || echo "None")

if [[ "$VPC_ID" != "None" && -n "$VPC_ID" ]]; then
  log_info "Found VPC: $VPC_ID - cleaning dependent resources..."

  # Delete Security Groups (not default)
  SG_IDS=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
    --output text)
  for sg in $SG_IDS; do
    log_delete "Deleting security group: $sg"
    run aws ec2 delete-security-group --group-id "$sg" --region "$REGION" 2>/dev/null || log_warn "Could not delete SG $sg (may have dependencies)"
  done

  # Release and delete NAT Gateways
  NAT_GWS=$(aws ec2 describe-nat-gateways \
    --region "$REGION" \
    --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" \
    --query 'NatGateways[].NatGatewayId' \
    --output text)
  for nat in $NAT_GWS; do
    log_delete "Deleting NAT Gateway: $nat"
    run aws ec2 delete-nat-gateway --nat-gateway-id "$nat" --region "$REGION" --output none
  done

  # Detach and delete Internet Gateways
  IGW_IDS=$(aws ec2 describe-internet-gateways \
    --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[].InternetGatewayId' \
    --output text)
  for igw in $IGW_IDS; do
    log_delete "Detaching and deleting IGW: $igw"
    run aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID" --region "$REGION"
    run aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION"
  done

  # Delete Subnets
  SUBNET_IDS=$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[].SubnetId' \
    --output text)
  for subnet in $SUBNET_IDS; do
    log_delete "Deleting subnet: $subnet"
    run aws ec2 delete-subnet --subnet-id "$subnet" --region "$REGION"
  done

  # Delete Route Tables (non-main)
  RT_IDS=$(aws ec2 describe-route-tables \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'RouteTables[?Associations[?Main!=`true`]].RouteTableId' \
    --output text)
  for rt in $RT_IDS; do
    log_delete "Deleting route table: $rt"
    run aws ec2 delete-route-table --route-table-id "$rt" --region "$REGION" 2>/dev/null || true
  done

  # Delete VPC
  log_delete "Deleting VPC: $VPC_ID"
  run aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION"
  log_success "VPC $VPC_ID deleted"
else
  log_warn "No VPC found for $PROJECT/$ENV"
fi

# ─────────────────────────────────────────────
# STEP 7: Release Elastic IPs
# ─────────────────────────────────────────────
log_info "Step 7/10: Releasing Elastic IPs..."

EIP_ALLOCS=$(aws ec2 describe-addresses \
  --region "$REGION" \
  --filters \
    "Name=tag:Project,Values=$TAG_VAL" \
    "Name=tag:Environment,Values=$ENV_VAL" \
  --query 'Addresses[].AllocationId' \
  --output text 2>/dev/null || echo "")

for alloc in $EIP_ALLOCS; do
  log_delete "Releasing EIP: $alloc"
  run aws ec2 release-address --allocation-id "$alloc" --region "$REGION"
done
log_success "EIPs released"

# ─────────────────────────────────────────────
# STEP 8: Delete CloudWatch Log Groups
# ─────────────────────────────────────────────
log_info "Step 8/10: Deleting CloudWatch log groups..."

LOG_GROUPS=$(aws logs describe-log-groups \
  --region "$REGION" \
  --log-group-name-prefix "/ecs/${PROJECT}/${ENV}" \
  --query 'logGroups[].logGroupName' \
  --output text 2>/dev/null || echo "")

LOG_GROUPS+=" $(aws logs describe-log-groups \
  --region "$REGION" \
  --log-group-name-prefix "/aws/vpc/flowlogs/${PROJECT}-${ENV}" \
  --query 'logGroups[].logGroupName' \
  --output text 2>/dev/null || echo "")"

for lg in $LOG_GROUPS; do
  [[ -z "$lg" ]] && continue
  log_delete "Deleting log group: $lg"
  run aws logs delete-log-group --log-group-name "$lg" --region "$REGION"
done
log_success "CloudWatch log groups deleted"

# ─────────────────────────────────────────────
# STEP 9: Delete IAM roles (env-specific)
# ─────────────────────────────────────────────
log_info "Step 9/10: Cleaning env-specific IAM roles..."

for role_suffix in "ecs-execution" "ecs-task" "vpc-flow-log"; do
  ROLE_NAME="${PROJECT}-${ENV}-${role_suffix}"
  if aws iam get-role --role-name "$ROLE_NAME" 2>/dev/null; then
    # Detach all managed policies
    POLICIES=$(aws iam list-attached-role-policies \
      --role-name "$ROLE_NAME" \
      --query 'AttachedPolicies[].PolicyArn' \
      --output text)
    for policy in $POLICIES; do
      run aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$policy"
    done

    # Delete inline policies
    INLINE=$(aws iam list-role-policies \
      --role-name "$ROLE_NAME" \
      --query 'PolicyNames[]' \
      --output text)
    for inline in $INLINE; do
      run aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$inline"
    done

    log_delete "Deleting IAM role: $ROLE_NAME"
    run aws iam delete-role --role-name "$ROLE_NAME"
  fi
done
log_success "IAM roles cleaned up"

# ─────────────────────────────────────────────
# STEP 10: Verify nothing tagged remains
# ─────────────────────────────────────────────
log_info "Step 10/10: Verifying cleanup completeness..."

REMAINING=$(aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=$TAG_KEY,Values=$TAG_VAL" "Key=$ENV_KEY,Values=$ENV_VAL" \
  --region "$REGION" \
  --query 'length(ResourceTagMappingList)' \
  --output text 2>/dev/null || echo "0")

# ── Final Report ──────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
if [[ "$REMAINING" == "0" || -z "$REMAINING" ]]; then
  echo -e "${GREEN} Cleanup Complete - 0 tagged resources remaining${NC}"
else
  echo -e "${YELLOW} Cleanup finished with $REMAINING resources still tagged${NC}"
  echo "  Run with --dry-run=false --force to investigate"
  aws resourcegroupstaggingapi get-resources \
    --tag-filters "Key=$TAG_KEY,Values=$TAG_VAL" "Key=$ENV_KEY,Values=$ENV_VAL" \
    --region "$REGION" \
    --query 'ResourceTagMappingList[].ResourceARN' \
    --output table 2>/dev/null || true
fi
echo "════════════════════════════════════════════════════════"
echo ""
exit $ERRORS