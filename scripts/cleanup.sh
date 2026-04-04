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
#   → RDS → ElastiCache → Secrets Manager → VPC (NAT GW → IGW → Subnets
#   → Route Tables → Security Groups) → EIPs → CloudWatch → IAM
# ─────────────────────────────────────────────────────────────────────────────

# set -e intentionally omitted: cleanup must continue past individual failures
set -uo pipefail

# Temp file for passing JSON to AWS CLI (e.g. ECR image IDs).
# mktemp avoids the fixed /tmp path race condition when multiple instances run.
# The EXIT trap guarantees cleanup regardless of how the script terminates.
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

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

# Wrapper: execute or just print in dry-run.
# Uses "$@" directly — no eval — to avoid shell re-parsing of arguments,
# which could interpret metacharacters in resource IDs or tag values.
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} Would run: $*"
  else
    "$@"
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

CLUSTER_ARNS=$(get_resources_by_tag "ecs:cluster")
for CLUSTER_ARN in $CLUSTER_ARNS; do
  [[ -z "$CLUSTER_ARN" ]] && continue
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
      --no-cli-pager

    run aws ecs delete-service \
      --cluster "$CLUSTER_NAME" \
      --service "$svc" \
      --force \
      --region "$REGION" \
      --no-cli-pager
  done

  # Wait for all services to become inactive (tasks fully drained)
  log_info "Waiting for ECS tasks to fully stop..."
  if [[ "$DRY_RUN" != "true" && -n "${SERVICES:-}" ]]; then
    # shellcheck disable=SC2086  # word splitting intentional for multiple service ARNs
    aws ecs wait services-inactive       --cluster "$CLUSTER_NAME"       --services $SERVICES       --region "$REGION" 2>/dev/null || {
      log_warn "Waiter timed out; some tasks may still be stopping — proceeding anyway"
      sleep 30
    }
  fi

  log_delete "Deleting ECS cluster: $CLUSTER_NAME"
  run aws ecs delete-cluster \
    --cluster "$CLUSTER_NAME" \
    --region "$REGION" \
    --no-cli-pager

  log_success "ECS cluster cleaned up: $CLUSTER_NAME"
done
if [[ -z "${CLUSTER_ARNS:-}" ]]; then
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
      # Write JSON to a temp file and pass via file:// — the AWS CLI's inline
      # JSON argument parsing is fragile with arrays; file:// is reliable.
      echo "$IMAGE_IDS" > "$TMPFILE"
      run aws ecr batch-delete-image \
        --repository-name "$REPO_NAME" \
        --image-ids "file://$TMPFILE" \
        --region "$REGION" \
        --no-cli-pager
    fi

    log_delete "Deleting ECR repository: $REPO_NAME"
    run aws ecr delete-repository \
      --repository-name "$REPO_NAME" \
      --region "$REGION" \
      --no-cli-pager
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
    --no-cli-pager

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
    --no-cli-pager

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
    --no-cli-pager
done
log_success "Secrets cleaned up"

# ─────────────────────────────────────────────
# STEP 6: Find and cleanup VPC resources
#
# Dependency order within the VPC:
#   NAT Gateways → (wait for deletion) → Internet Gateways
#   → Subnets → Route Tables (disassociate first) → Security Groups → VPC
#
# Security groups MUST be deleted after NAT gateways are fully gone.
# NAT gateways hold ENIs that reference security groups — deleting SGs
# before NAT GW deletion completes causes dependency errors.
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

  # ── 6a: NAT Gateways (must go first — they hold ENIs that reference SGs) ──
  # Include pending/deleting states — stuck NAT GWs from prior runs still
  # block VPC deletion even though they can't be deleted again
  NAT_GWS=$(aws ec2 describe-nat-gateways     --region "$REGION"     --filter "Name=vpc-id,Values=$VPC_ID"       "Name=state,Values=pending,available,deleting"     --query 'NatGateways[].NatGatewayId'     --output text)
  for nat in $NAT_GWS; do
    STATE=$(aws ec2 describe-nat-gateways       --nat-gateway-ids "$nat"       --region "$REGION"       --query 'NatGateways[0].State'       --output text 2>/dev/null || echo "unknown")
    if [[ "$STATE" == "available" || "$STATE" == "pending" ]]; then
      log_delete "Deleting NAT Gateway: $nat (state: $STATE)"
      run aws ec2 delete-nat-gateway --nat-gateway-id "$nat" --region "$REGION" --no-cli-pager
    else
      log_info "NAT Gateway $nat already in state: $STATE — waiting for it to finish"
    fi
  done

  # NAT Gateways take 60-90s to fully delete. Subnets, SGs, and VPC cannot be
  # removed while a NAT GW is still in 'deleting' state, so we wait here.
  if [[ -n "$NAT_GWS" && "$DRY_RUN" != "true" ]]; then
    log_info "Waiting for NAT Gateways to finish deleting..."
    for nat in $NAT_GWS; do
      aws ec2 wait nat-gateway-deleted \
        --nat-gateway-ids "$nat" \
        --region "$REGION" 2>/dev/null || true
    done
    log_success "NAT Gateways deleted"
  fi

  # ── 6b: Internet Gateways ─────────────────────────────────────────────────
  IGW_IDS=$(aws ec2 describe-internet-gateways \
    --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[].InternetGatewayId' \
    --output text)
  for igw in $IGW_IDS; do
    log_delete "Detaching and deleting IGW: $igw"
    run aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID" --region "$REGION" --no-cli-pager
    run aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" --no-cli-pager
  done

  # ── 6c: Subnets ───────────────────────────────────────────────────────────
  SUBNET_IDS=$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[].SubnetId' \
    --output text)
  for subnet in $SUBNET_IDS; do
    log_delete "Deleting subnet: $subnet"
    run aws ec2 delete-subnet --subnet-id "$subnet" --region "$REGION"
  done

  # ── 6d: Route Tables (disassociate before deleting) ───────────────────────
  RT_IDS=$(aws ec2 describe-route-tables \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'RouteTables[?Associations[?Main!=`true`]].RouteTableId' \
    --output text)
  for rt in $RT_IDS; do
    # Disassociate all non-main associations first — route tables with active
    # subnet associations cannot be deleted directly
    ASSOC_IDS=$(aws ec2 describe-route-tables \
      --route-table-ids "$rt" \
      --region "$REGION" \
      --query 'RouteTables[].Associations[?Main!=`true`].RouteTableAssociationId' \
      --output text 2>/dev/null || echo "")
    for assoc in $ASSOC_IDS; do
      [[ -z "$assoc" ]] && continue
      run aws ec2 disassociate-route-table --association-id "$assoc" --region "$REGION"
    done
    log_delete "Deleting route table: $rt"
    run aws ec2 delete-route-table --route-table-id "$rt" --region "$REGION" 2>/dev/null || true
  done

  # ── 6e: Security Groups (AFTER NAT GW wait — see note above) ─────────────
  SG_IDS=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
    --output text)
  for sg in $SG_IDS; do
    log_delete "Deleting security group: $sg"
    if ! run aws ec2 delete-security-group --group-id "$sg" --region "$REGION" --no-cli-pager 2>/dev/null; then
      if [[ "$DRY_RUN" != "true" ]]; then
        log_warn "Could not delete SG $sg (may have dependencies)"
        ((ERRORS++)) || true
      fi
    fi
  done

  # ── 6f: VPC ───────────────────────────────────────────────────────────────
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

    # Remove from instance profiles first — delete-role fails with
    # DeleteConflict if the role is still attached to a profile
    INSTANCE_PROFILES=$(aws iam list-instance-profiles-for-role \
      --role-name "$ROLE_NAME" \
      --query 'InstanceProfiles[].InstanceProfileName' \
      --output text 2>/dev/null || echo "")
    for profile in $INSTANCE_PROFILES; do
      [[ -z "$profile" ]] && continue
      run aws iam remove-role-from-instance-profile \
        --instance-profile-name "$profile" \
        --role-name "$ROLE_NAME"
      run aws iam delete-instance-profile \
        --instance-profile-name "$profile"
    done

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
  echo "  Re-run without --dry-run to investigate, or check AWS console"
  aws resourcegroupstaggingapi get-resources \
    --tag-filters "Key=$TAG_KEY,Values=$TAG_VAL" "Key=$ENV_KEY,Values=$ENV_VAL" \
    --region "$REGION" \
    --query 'ResourceTagMappingList[].ResourceARN' \
    --output table 2>/dev/null || true
fi
echo "════════════════════════════════════════════════════════"
echo ""
exit $ERRORS