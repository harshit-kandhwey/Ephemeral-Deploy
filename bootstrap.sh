#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# bootstrap.sh — One-time AWS setup for NexusDeploy
#
# Creates:
#   1. S3 bucket          — Terraform remote state
#   2. GitHub OIDC provider — keyless auth for GitHub Actions
#   3. IAM role            — assumed by GitHub Actions via OIDC
#   4. SSM parameters      — all app secrets, stored encrypted
#
# Usage (run from repo root):
#   export GITHUB_ORG=your-github-username
#   export GITHUB_REPO=Ephemeral-Deploy    # exact repo name on GitHub
#   export ENV=dev                          # dev or prod
#   make bootstrap
#     OR
#   AWS_REGION=us-east-1 ./scripts/bootstrap.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Config ────────────────────────────────────
REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT:-nexusdeploy}"
ENV="${ENV:-dev}"
STATE_BUCKET="${PROJECT}-terraform-state"
LOCK_TABLE="${PROJECT}-terraform-locks"
GITHUB_ORG="${GITHUB_ORG:-}"
GITHUB_REPO="${GITHUB_REPO:-Ephemeral-Deploy}"

# ── Colours ───────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── Pre-flight checks ─────────────────────────
if [[ -z "$GITHUB_ORG" ]]; then
  log_error "GITHUB_ORG is not set.\n  Run: export GITHUB_ORG=your-github-username"
fi

echo ""
echo "════════════════════════════════════════════════════════"
echo " NexusDeploy Bootstrap"
echo " Project:     $PROJECT"
echo " Environment: $ENV"
echo " Region:      $REGION"
echo " GitHub:      $GITHUB_ORG/$GITHUB_REPO"
echo "════════════════════════════════════════════════════════"
echo ""

# ── Verify AWS credentials ────────────────────
log_info "Verifying AWS credentials..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || log_error "AWS credentials not configured. Run 'aws configure' first."
log_success "Connected: account=$ACCOUNT_ID region=$REGION"

# ──────────────────────────────────────────────
# STEP 1: S3 STATE BUCKET
# ──────────────────────────────────────────────
log_info "Creating Terraform state S3 bucket: $STATE_BUCKET"

if aws s3api head-bucket --bucket "$STATE_BUCKET" --region "$REGION" 2>/dev/null; then
  log_warn "Bucket $STATE_BUCKET already exists — skipping creation"
else
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket \
      --bucket "$STATE_BUCKET" \
      --region "$REGION"
  else
    aws s3api create-bucket \
      --bucket "$STATE_BUCKET" \
      --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  log_success "Created bucket: s3://$STATE_BUCKET"
fi

# Enable versioning — keeps history of every state file change.
# Essential for disaster recovery: if state gets corrupted you can
# roll back to any previous version.
aws s3api put-bucket-versioning \
  --bucket "$STATE_BUCKET" \
  --versioning-configuration Status=Enabled
log_success "Versioning enabled on s3://$STATE_BUCKET"

# Enable server-side encryption — state files contain resource IDs
# and ARNs; AES256 is free and adds a layer of protection at rest.
aws s3api put-bucket-encryption \
  --bucket "$STATE_BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      },
      "BucketKeyEnabled": true
    }]
  }'
log_success "AES256 encryption enabled on s3://$STATE_BUCKET"

# Block all public access — state files must never be public.
aws s3api put-public-access-block \
  --bucket "$STATE_BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
log_success "Public access blocked on s3://$STATE_BUCKET"

# ──────────────────────────────────────────────
# STEP 2: DYNAMODB STATE LOCKING (commented out)
# Single-developer workflow — no concurrent runs possible,
# so locking adds cost/complexity with no benefit.
#
# To enable for a team:
#   1. Uncomment the block below
#   2. Add dynamodb_table to backend config in deploy.yml
#   3. Add dynamodb_table to backend block in each environment's main.tf
# Cost: $0 — DynamoDB PAY_PER_REQUEST with <25 ops/day is negligible
# ──────────────────────────────────────────────

# log_info "Creating DynamoDB state lock table: $LOCK_TABLE"
# if aws dynamodb describe-table --table-name "$LOCK_TABLE" --region "$REGION" 2>/dev/null; then
#   log_warn "Table $LOCK_TABLE already exists — skipping"
# else
#   aws dynamodb create-table \
#     --table-name "$LOCK_TABLE" \
#     --attribute-definitions AttributeName=LockID,AttributeType=S \
#     --key-schema AttributeName=LockID,KeyType=HASH \
#     --billing-mode PAY_PER_REQUEST \
#     --region "$REGION" \
#     --tags Key=Project,Value="$PROJECT" Key=ManagedBy,Value=bootstrap
#   aws dynamodb wait table-exists --table-name "$LOCK_TABLE" --region "$REGION"
#   log_success "Created DynamoDB table: $LOCK_TABLE"
# fi

# ──────────────────────────────────────────────
# STEP 3: GITHUB OIDC PROVIDER
# Allows GitHub Actions to authenticate with AWS without
# storing any long-lived credentials in GitHub Secrets.
# ──────────────────────────────────────────────
log_info "Creating GitHub Actions OIDC provider..."

OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

if aws iam get-open-id-connect-provider \
     --open-id-connect-provider-arn "$OIDC_ARN" 2>/dev/null; then
  log_warn "OIDC provider already exists — skipping"
else
  aws iam create-open-id-connect-provider \
    --url "https://token.actions.githubusercontent.com" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list \
      "6938fd4d98bab03faadb97b34396831e3780aea1" \
      "aadc6b94e76cfcf49af8e4ea9a6a07f5f1c98e4f"
  log_success "OIDC provider created for GitHub Actions"
fi

# ──────────────────────────────────────────────
# STEP 4: IAM DEPLOY ROLE
# GitHub Actions assumes this role via OIDC.
# Trust policy restricts to this specific repo only.
# ──────────────────────────────────────────────
log_info "Creating GitHub Actions deploy role..."

ROLE_NAME="${PROJECT}-github-actions-deploy"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:*"
        }
      }
    }
  ]
}
EOF
)

if aws iam get-role --role-name "$ROLE_NAME" 2>/dev/null; then
  log_warn "Role $ROLE_NAME already exists — skipping creation"
  # Update trust policy in case GITHUB_ORG/REPO changed
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "$TRUST_POLICY"
  log_success "Trust policy updated for $ROLE_NAME"
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "GitHub Actions OIDC deploy role for NexusDeploy CI/CD" \
    --tags Key=Project,Value="$PROJECT" Key=ManagedBy,Value=bootstrap

  # AdministratorAccess for bootstrap only.
  # After first terraform apply, the IAM module creates a least-privilege
  # policy. You can then detach AdministratorAccess and rely on that instead.
  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/AdministratorAccess"

  log_success "Role created: $ROLE_NAME"
  log_warn "⚠️  AdministratorAccess attached for bootstrap."
  log_warn "   After first deploy, replace with the least-privilege"
  log_warn "   policy created by the IAM Terraform module."
fi

# ──────────────────────────────────────────────
# STEP 5: SSM SECRETS
# All credentials stored as SSM SecureString parameters.
# Values are entered interactively — never written to any file.
#
# Secret path layout:
#   /<project>/<env>/db/master_username    RDS superuser name
#   /<project>/<env>/db/master_password    RDS superuser password  (SecureString)
#   /<project>/<env>/db/app_username       App DB user name
#   /<project>/<env>/db/app_password       App DB user password    (SecureString)
#   /<project>/<env>/app/secret_key        Flask SECRET_KEY        (SecureString)
#   /<project>/<env>/app/jwt_secret_key    JWT signing key         (SecureString)
#   /<project>/<env>/monitoring/grafana_password  Grafana password  (SecureString)
# ──────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo " SSM Secrets Setup — ENV=$ENV"
echo " You will be prompted for each value."
echo " Press Enter to skip any that are already set."
echo "════════════════════════════════════════════════════════"
echo ""

# Suggest random values for secret keys
SUGGESTED_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null \
  || openssl rand -hex 32)
echo -e "  ${BLUE}💡 Suggested value for secret keys:${NC}"
echo "     $SUGGESTED_KEY"
echo "     (run the command again to get a different one)"
echo ""

create_ssm_param() {
  local path="/$PROJECT/$ENV/$1"
  local description="$2"
  local secure="${3:-true}"
  local param_type
  param_type=$([[ "$secure" == "true" ]] && echo "SecureString" || echo "String")

  # Check if already exists
  if aws ssm get-parameter --name "$path" --region "$REGION" &>/dev/null; then
    log_warn "Already exists — skipping: $path"
    return 0
  fi

  if [[ "$secure" == "true" ]]; then
    read -rsp "  [$param_type] $path  ($description): " value
  else
    read -rp  "  [$param_type] $path  ($description): " value
  fi
  echo ""

  if [[ -z "$value" ]]; then
    log_warn "  Skipped (empty input): $path"
    return 0
  fi

  aws ssm put-parameter \
    --name "$path" \
    --value "$value" \
    --type "$param_type" \
    --description "$description" \
    --region "$REGION" \
    --tags Key=Project,Value="$PROJECT" Key=Environment,Value="$ENV" \
           Key=ManagedBy,Value=bootstrap \
    --no-cli-pager
  log_success "  Stored: $path"
}

create_ssm_param "db/master_username"          "RDS superuser name (e.g. nexusadmin)"           false
create_ssm_param "db/master_password"          "RDS superuser password — use a strong password"  true
create_ssm_param "db/app_username"             "App DB user name (e.g. nexusapp)"                false
create_ssm_param "db/app_password"             "App DB user password — use a strong password"    true
create_ssm_param "app/secret_key"              "Flask SECRET_KEY — use the suggested hex above"  true
create_ssm_param "app/jwt_secret_key"          "JWT signing key — use a different hex value"     true
create_ssm_param "monitoring/grafana_password" "Grafana admin UI password"                       true

# ── Summary ───────────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN} Bootstrap Complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""
echo "  S3 State Bucket : s3://$STATE_BUCKET  (versioned + encrypted)"
echo "  OIDC Provider   : $OIDC_ARN"
echo "  IAM Role        : $ROLE_ARN"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo ""
echo "  1. Add this secret to GitHub:"
echo "     Repository → Settings → Secrets and variables → Actions"
echo "     Name:  AWS_DEPLOY_ROLE_ARN"
echo "     Value: $ROLE_ARN"
echo ""
echo "  2. Create GitHub Environments (Settings → Environments):"
echo "     • dev  — no approval gate"
echo "     • prod — enable Required reviewers (add yourself)"
echo ""
echo "  3. Verify terraform.tfvars in both environments:"
echo "     terraform/environments/dev/terraform.tfvars"
echo "       github_org  = \"$GITHUB_ORG\""
echo "       github_repo = \"$GITHUB_REPO\""
echo ""
echo "  4. Push to trigger your first deployment:"
echo "     git push origin dev"
echo ""
echo "  5. After first successful deploy, tighten IAM:"
echo "     Detach AdministratorAccess from $ROLE_NAME"
echo "     Attach the least-privilege policy created by the IAM module"
echo ""