#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# bootstrap.sh - One-time AWS setup
# Creates: S3 state bucket, OIDC provider, IAM role, SSM secrets
#
# Usage:
#   export GITHUB_ORG=your-username
#   export ENV=dev    # or prod
#   ./scripts/bootstrap.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT:-nexusdeploy}"
ENV="${ENV:-dev}"
STATE_BUCKET="${PROJECT}-terraform-state"
GITHUB_ORG="${GITHUB_ORG:-YOUR_GITHUB_ORG}"
GITHUB_REPO="${GITHUB_REPO:-nexusdeploy}"

if [[ "$GITHUB_ORG" == "YOUR_GITHUB_ORG" ]]; then
  log_error "GITHUB_ORG not set. Export it before running: export GITHUB_ORG=your-username"
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo ""
echo "════════════════════════════════════════════"
echo " NexusDeploy Bootstrap"
echo " Environment: $ENV | Region: $REGION"
echo "════════════════════════════════════════════"

# ── Verify AWS credentials ────────────────────
log_info "Verifying AWS credentials..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || log_error "AWS credentials not configured. Run 'aws configure' first."
log_success "Connected as account: $ACCOUNT_ID in region: $REGION"

# ── Create S3 Bucket ──────────────────────────
log_info "Creating Terraform state S3 bucket: $STATE_BUCKET"

if aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
  log_warn "Bucket $STATE_BUCKET already exists, skipping creation"
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
  log_success "Created bucket: $STATE_BUCKET"
fi

# Enable versioning (keeps history of state changes)
#aws s3api put-bucket-versioning \
#  --bucket "$STATE_BUCKET" \
#  --versioning-configuration Status=Enabled
log_warn "Versioning skipped for $STATE_BUCKET, for demo. Consider enabling for production use."

# Enable encryption at rest
# aws s3api put-bucket-encryption \
#   --bucket "$STATE_BUCKET" \
#   --server-side-encryption-configuration '{
#     "Rules": [{
#       "ApplyServerSideEncryptionByDefault": {
#         "SSEAlgorithm": "AES256"
#       }
#     }]
#   }'
log_warn "Encryption skipped on $STATE_BUCKET, for demo. Consider enabling for production use."

# Block all public access (security hardening)
aws s3api put-public-access-block \
  --bucket "$STATE_BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
log_success "Public access blocked on $STATE_BUCKET"

# Lifecycle policy - transition old state versions to cheaper storage
# aws s3api put-bucket-lifecycle-configuration \
#   --bucket "$STATE_BUCKET" \
#   --lifecycle-configuration '{
#     "Rules": [{
#       "ID": "StateFileVersions",
#       "Status": "Enabled",
#       "Filter": {},
#       "NoncurrentVersionTransitions": [{
#         "NoncurrentDays": 30,
#         "StorageClass": "STANDARD_IA"
#       }],
#       "NoncurrentVersionExpiration": {
#         "NoncurrentDays": 90
#       }
#     }]
#   }'
log_warn "Lifecycle policy skipped on $STATE_BUCKET, for demo. Consider enabling for production use."

# Create folder structure for environments
for env in dev prod backups; do
  aws s3api put-object \
    --bucket "$STATE_BUCKET" \
    --key "$env/" \
    --content-length 0 2>/dev/null || true
  log_success "Created folder: $env/"
done

# ── DynamoDB State Locking (COMMENTED OUT) ────
#
# We're not using DynamoDB state locking because only one environment
# runs at a time in this project (single developer, sequential deploys).
# This avoids the ~$0/month cost (PAY_PER_REQUEST is free at low volume,
# but we prefer zero infrastructure overhead).
#
# TO ENABLE locking for a team setup:
#   1. Uncomment the block below
#   2. In deploy.yml, uncomment: -backend-config="dynamodb_table=..."
#   3. In each environment's main.tf backend block, uncomment the dynamodb_table line


# log_info "Creating DynamoDB table for state locking: $LOCK_TABLE"

# if aws dynamodb describe-table --table-name "$LOCK_TABLE" --region "$REGION" 2>/dev/null; then
#   log_warn "Table $LOCK_TABLE already exists, skipping creation"
# else
#   aws dynamodb create-table \
#     --table-name "$LOCK_TABLE" \
#     --attribute-definitions AttributeName=LockID,AttributeType=S \
#     --key-schema AttributeName=LockID,KeyType=HASH \
#     --billing-mode PAY_PER_REQUEST \
#     --region "$REGION" \
#     --tags \
#       Key=Project,Value="$PROJECT" \
#       Key=ManagedBy,Value=bootstrap

#   aws dynamodb wait table-exists \
#     --table-name "$LOCK_TABLE" \
#     --region "$REGION"

#   log_success "Created DynamoDB table: $LOCK_TABLE"
# fi


# ── Create OIDC Provider for GitHub Actions ───
# GitHub OIDC root CA thumbprints (DigiCert Global Root G2 and RSA Root CA)
log_info "Creating GitHub OIDC provider for IAM authentication..."

OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" 2>/dev/null; then
  log_warn "OIDC provider already exists, skipping"
else
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 aadc6b94e76cfcf49af8e4ea9a6a07f5f1c98e4f
  log_success "OIDC provider created for GitHub Actions"
fi

# ── Create Bootstrap IAM Role (for initial Terraform) ─
log_info "Creating initial GitHub Actions deploy role..."

ROLE_NAME="${PROJECT}-github-actions-deploy"
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
  log_warn "Role $ROLE_NAME already exists"
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "GitHub Actions OIDC role for NexusDeploy CI/CD"

  # Bootstrap permission: enough to run first Terraform
  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

  log_warn "⚠️  Attached AdministratorAccess for bootstrap."
  log_warn "   After first Terraform apply, the IAM module will create"
  log_warn "   a least-privilege policy. Replace this broad policy then."
fi

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"


# ══════════════════════════════════════════════
# SSM SECRETS SETUP
# All credentials stored as SSM SecureString parameters.
# These are created interactively - never stored in files.
#
# Secret hierarchy:
#   /<project>/<env>/db/master_username   → RDS superuser name
#   /<project>/<env>/db/master_password   → RDS superuser password (SecureString)
#   /<project>/<env>/db/app_username      → App DB user (limited privileges)
#   /<project>/<env>/db/app_password      → App DB user password (SecureString)
#   /<project>/<env>/app/secret_key       → Flask SECRET_KEY (SecureString)
#   /<project>/<env>/app/jwt_secret_key   → JWT signing key (SecureString)
#   /<project>/<env>/monitoring/grafana_password → Grafana admin password (SecureString)
# ══════════════════════════════════════════════
echo ""
log_info "Setting up SSM secrets for environment: $ENV"
echo "(You will be prompted to enter each value. Press Enter to skip if already set.)"
echo ""

create_ssm_secret() {
  local name="/$PROJECT/$ENV/$1"
  local description="$2"
  local is_secure="${3:-true}"
  local type=$([[ "$is_secure" == "true" ]] && echo "SecureString" || echo "String")

  if aws ssm get-parameter --name "$name" --region "$REGION" &>/dev/null; then
    log_warn "SSM $name already exists, skipping"
    return
  fi

  read -rsp "  Enter value for $name ($description): " value
  echo ""
  [[ -z "$value" ]] && { log_warn "  Skipped (empty)"; return; }

  aws ssm put-parameter \
    --name "$name" \
    --value "$value" \
    --type "$type" \
    --description "$description" \
    --region "$REGION"
  log_success "  Created: $name"
}

# Generate random values suggestion
SUGGESTED_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null || openssl rand -hex 32)
echo "  💡 Suggested random value for keys: $SUGGESTED_SECRET"
echo ""

create_ssm_secret "db/master_username"         "RDS superuser name (e.g. nexusadmin)" false
create_ssm_secret "db/master_password"         "RDS superuser password - store securely!" true
create_ssm_secret "db/app_username"            "App DB user name (e.g. nexusapp)" false
create_ssm_secret "db/app_password"            "App DB user password" true
create_ssm_secret "app/secret_key"             "Flask SECRET_KEY - use random hex" true
create_ssm_secret "app/jwt_secret_key"         "JWT signing key - use random hex" true
create_ssm_secret "monitoring/grafana_password" "Grafana admin UI password" true

# ── Summary ───────────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN} Bootstrap Complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""
echo "Resources created:"
echo "  S3 Bucket:       s3://$STATE_BUCKET"
echo "  DynamoDB Table:  ${LOCK_TABLE:-"<not set>"}"
echo "  OIDC Provider:   $OIDC_ARN"
echo "  IAM Role:        $ROLE_NAME"
echo ""
echo "Next steps:"
echo "  1. Add to GitHub Secrets:"
echo "     AWS_DEPLOY_ROLE_ARN = $ROLE_ARN"
echo ""
echo "Then update terraform/environments/$ENV/terraform.tfvars:"
echo "  github_org = \"$GITHUB_ORG\""
echo ""
echo "Push to the '$ENV' branch to trigger your first deployment!"
echo ""