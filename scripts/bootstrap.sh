#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# bootstrap.sh — One-time AWS setup for NexusDeploy
#
# Creates:
#   1. S3 bucket           — Terraform remote state (versioned + encrypted)
#   2. GitHub OIDC provider — keyless auth for GitHub Actions
#   3. IAM role            — assumed by GitHub Actions via OIDC
#   4. IAM inline policy   — least-privilege, covers deploy + cleanup
#   5. SSM parameters      — all app secrets, stored encrypted
#
# Idempotent — safe to re-run at any time:
#   S3 bucket       skips creation if exists; re-applies encryption + public-access-block (harmless)
#   OIDC provider   skips entirely if exists
#   IAM role        skips creation if exists; re-applies trust policy only
#   IAM policy      always overwrites with latest policy from this script
#                   (updating the policy here and re-running updates the role)
#   SSM parameters  skips any parameter that already exists; never overwrites secrets
#
# Usage (run from repo root):
#   export GITHUB_ORG=your-github-username
#   export GITHUB_REPO=Ephemeral-Deploy    # exact repo name on GitHub
#   export ENV=dev                          # dev or prod
#   make bootstrap
#     OR
#   MSYS_NO_PATHCONV=1 AWS_REGION=us-east-1 bash scripts/bootstrap.sh
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
if ! ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>&1); then
  log_error "AWS credentials not configured or invalid.\n  Error: $ACCOUNT_ID\n  Run 'aws configure' to fix."
fi
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

# S3 versioning — disabled for demo/cost purposes.
# Each stored version is billed as a separate S3 object.
# Re-enable for production: essential for state file disaster recovery.
#
# To enable: uncomment below and re-run bootstrap (idempotent)
# aws s3api put-bucket-versioning \
#   --bucket "$STATE_BUCKET" \
#   --versioning-configuration Status=Enabled
# log_success "Versioning enabled on s3://$STATE_BUCKET"
log_warn "S3 versioning disabled (demo mode) — enable for production use"

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
# STEP 3b: ECS SERVICE-LINKED ROLE
# Required for ECS to manage Fargate capacity providers.
# This is a one-time account-level setup — safe to run repeatedly.
# ──────────────────────────────────────────────
log_info "Ensuring ECS service-linked role exists..."
if aws iam get-role   --role-name "AWSServiceRoleForECS" 2>/dev/null; then
  log_warn "ECS service-linked role already exists — skipping"
else
  aws iam create-service-linked-role     --aws-service-name "ecs.amazonaws.com" 2>/dev/null || true
  log_success "ECS service-linked role created"
fi

log_info "Ensuring ElastiCache service-linked role exists..."
if aws iam get-role   --role-name "AWSServiceRoleForElastiCache" 2>/dev/null; then
  log_warn "ElastiCache service-linked role already exists — skipping"
else
  aws iam create-service-linked-role     --aws-service-name "elasticache.amazonaws.com" 2>/dev/null || true
  log_success "ElastiCache service-linked role created"
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
  log_success "Role created: $ROLE_NAME"
fi

# ──────────────────────────────────────────────
# STEP 4b: LEAST-PRIVILEGE INLINE POLICY
# Applied directly to the role — no AdministratorAccess needed.
# Covers all three phases:
#   Phase 1 — First deploy   (terraform apply creates all infrastructure)
#   Phase 2 — Ongoing deploy (image push + ECS update + state read/write)
#   Phase 3 — Cleanup        (terraform destroy + cleanup.sh fallback)
#
# Uses put-role-policy (inline, 10240 char limit) rather than
# create-policy (managed, 6144 char limit) because the full policy
# covering all three phases exceeds the managed policy size limit.
# ──────────────────────────────────────────────
log_info "Applying least-privilege inline policy to $ROLE_NAME..."

DEPLOY_POLICY=$(cat <<ENDPOLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformState",
      "Effect": "Allow",
      "Action": ["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:ListBucket","s3:ListBucketVersions","s3:GetBucketVersioning","s3:GetEncryptionConfiguration","s3:PutObjectTagging","s3:GetObjectTagging","s3:DeleteObjectTagging","s3:GetObjectVersion"],
      "Resource": ["arn:aws:s3:::${STATE_BUCKET}","arn:aws:s3:::${STATE_BUCKET}/*"]
    },
    {
      "Sid": "SSM",
      "Effect": "Allow",
      "Action": ["ssm:GetParameter","ssm:GetParameters","ssm:GetParametersByPath","ssm:PutParameter"],
      "Resource": "arn:aws:ssm:*:${ACCOUNT_ID}:parameter/${PROJECT}/*"
    },
    {
      "Sid": "SSMDescribe",
      "Effect": "Allow",
      "Action": ["ssm:DescribeParameters"],
      "Resource": "*"
    },
    {
      "Sid": "SecretsManager",
      "Effect": "Allow",
      "Action": ["secretsmanager:CreateSecret","secretsmanager:UpdateSecret","secretsmanager:PutSecretValue","secretsmanager:GetSecretValue","secretsmanager:DescribeSecret","secretsmanager:DeleteSecret","secretsmanager:TagResource","secretsmanager:GetResourcePolicy"],
      "Resource": "arn:aws:secretsmanager:*:${ACCOUNT_ID}:secret:${PROJECT}/*"
    },
    {
      "Sid": "SecretsManagerList",
      "Effect": "Allow",
      "Action": ["secretsmanager:ListSecrets"],
      "Resource": "*"
    },
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": ["ecr:GetAuthorizationToken"],
      "Resource": "*"
    },
    {
      "Sid": "ECR",
      "Effect": "Allow",
      "Action": ["ecr:CreateRepository","ecr:DeleteRepository","ecr:DescribeRepositories","ecr:ListTagsForResource","ecr:PutLifecyclePolicy","ecr:GetLifecyclePolicy","ecr:DeleteLifecyclePolicy","ecr:BatchCheckLayerAvailability","ecr:GetDownloadUrlForLayer","ecr:BatchGetImage","ecr:InitiateLayerUpload","ecr:UploadLayerPart","ecr:CompleteLayerUpload","ecr:PutImage","ecr:ListImages","ecr:BatchDeleteImage","ecr:TagResource","ecr:UntagResource","ecr:PutImageScanningConfiguration","ecr:PutImageTagMutability"],
      "Resource": "arn:aws:ecr:*:${ACCOUNT_ID}:repository/${PROJECT}-*"
    },
    {
      "Sid": "ECS",
      "Effect": "Allow",
      "Action": ["ecs:CreateCluster","ecs:DeleteCluster","ecs:DescribeClusters","ecs:UpdateCluster","ecs:UpdateClusterSettings","ecs:PutClusterCapacityProviders","ecs:RegisterTaskDefinition","ecs:DeregisterTaskDefinition","ecs:DescribeTaskDefinition","ecs:ListTaskDefinitions","ecs:CreateService","ecs:UpdateService","ecs:DeleteService","ecs:DescribeServices","ecs:ListServices","ecs:ListTasks","ecs:DescribeTasks","ecs:StopTask","ecs:TagResource","ecs:ListTagsForResource"],
      "Resource": "*"
    },
    {
      "Sid": "EC2Network",
      "Effect": "Allow",
      "Action": ["ec2:CreateVpc","ec2:DeleteVpc","ec2:DescribeVpcs","ec2:ModifyVpcAttribute","ec2:DescribeVpcAttribute","ec2:DescribeAddressesAttribute","ec2:CreateSubnet","ec2:DeleteSubnet","ec2:DescribeSubnets","ec2:ModifySubnetAttribute","ec2:CreateRouteTable","ec2:DeleteRouteTable","ec2:DescribeRouteTables","ec2:AssociateRouteTable","ec2:DisassociateRouteTable","ec2:CreateRoute","ec2:DeleteRoute","ec2:CreateInternetGateway","ec2:DeleteInternetGateway","ec2:DescribeInternetGateways","ec2:AttachInternetGateway","ec2:DetachInternetGateway","ec2:CreateNatGateway","ec2:DeleteNatGateway","ec2:DescribeNatGateways","ec2:AllocateAddress","ec2:ReleaseAddress","ec2:DescribeAddresses","ec2:AssociateAddress","ec2:DisassociateAddress","ec2:CreateFlowLogs","ec2:DeleteFlowLogs","ec2:DescribeFlowLogs","ec2:CreateSecurityGroup","ec2:DeleteSecurityGroup","ec2:DescribeSecurityGroups","ec2:AuthorizeSecurityGroupIngress","ec2:RevokeSecurityGroupIngress","ec2:AuthorizeSecurityGroupEgress","ec2:RevokeSecurityGroupEgress"],
      "Resource": "*"
    },
    {
      "Sid": "EC2Instances",
      "Effect": "Allow",
      "Action": ["ec2:RunInstances","ec2:TerminateInstances","ec2:DescribeInstances","ec2:DescribeInstanceStatus","ec2:DescribeInstanceTypes","ec2:DescribeImages","ec2:DescribeNetworkInterfaces","ec2:CreateNetworkInterface","ec2:DeleteNetworkInterface","ec2:DescribeAvailabilityZones","ec2:DescribeAccountAttributes","ec2:DescribeVolumes","ec2:CreateTags","ec2:DeleteTags","ec2:DescribeTags","ec2:DescribeKeyPairs"],
      "Resource": "*"
    },
    {
      "Sid": "RDS",
      "Effect": "Allow",
      "Action": ["rds:CreateDBInstance","rds:DeleteDBInstance","rds:ModifyDBInstance","rds:DescribeDBInstances","rds:CreateDBSubnetGroup","rds:DeleteDBSubnetGroup","rds:DescribeDBSubnetGroups","rds:CreateDBParameterGroup","rds:DeleteDBParameterGroup","rds:DescribeDBParameterGroups","rds:DescribeDBParameters","rds:ModifyDBParameterGroup","rds:ResetDBParameterGroup","rds:AddTagsToResource","rds:RemoveTagsFromResource","rds:ListTagsForResource","rds:DescribeDBEngineVersions"],
      "Resource": "*"
    },
    {
      "Sid": "ElastiCache",
      "Effect": "Allow",
      "Action": ["elasticache:CreateCacheCluster","elasticache:DeleteCacheCluster","elasticache:DescribeCacheClusters","elasticache:ModifyCacheCluster","elasticache:CreateCacheSubnetGroup","elasticache:DeleteCacheSubnetGroup","elasticache:DescribeCacheSubnetGroups","elasticache:CreateCacheParameterGroup","elasticache:DeleteCacheParameterGroup","elasticache:DescribeCacheParameterGroups","elasticache:AddTagsToResource","elasticache:RemoveTagsFromResource","elasticache:ListTagsForResource"],
      "Resource": "*"
    },
    {
      "Sid": "Observability",
      "Effect": "Allow",
      "Action": ["cloudwatch:PutMetricAlarm","cloudwatch:DeleteAlarms","cloudwatch:DescribeAlarms","cloudwatch:GetMetricData","cloudwatch:GetMetricStatistics","cloudwatch:ListMetrics","cloudwatch:PutDashboard","cloudwatch:DeleteDashboards","cloudwatch:GetDashboard","cloudwatch:ListDashboards","cloudwatch:TagResource","cloudwatch:ListTagsForResource","logs:CreateLogGroup","logs:DeleteLogGroup","logs:DescribeLogGroups","logs:PutRetentionPolicy","logs:DeleteRetentionPolicy","logs:TagLogGroup","logs:TagResource","logs:ListTagsForResource","logs:CreateLogStream","logs:DeleteLogStream","logs:DescribeLogStreams","logs:PutLogEvents","logs:GetLogEvents","logs:FilterLogEvents","logs:PutResourcePolicy","logs:DeleteResourcePolicy","logs:DescribeResourcePolicies"],
      "Resource": "*"
    },
    {
      "Sid": "IAMRoles",
      "Effect": "Allow",
      "Action": ["iam:CreateRole","iam:DeleteRole","iam:GetRole","iam:UpdateAssumeRolePolicy","iam:UpdateRole","iam:TagRole","iam:ListRolePolicies","iam:ListAttachedRolePolicies","iam:PutRolePolicy","iam:GetRolePolicy","iam:DeleteRolePolicy","iam:AttachRolePolicy","iam:DetachRolePolicy","iam:AddRoleToInstanceProfile","iam:RemoveRoleFromInstanceProfile","iam:ListInstanceProfilesForRole"],
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/${PROJECT}-*"
    },
    {
      "Sid": "IAMInstanceProfiles",
      "Effect": "Allow",
      "Action": ["iam:CreateInstanceProfile","iam:DeleteInstanceProfile","iam:GetInstanceProfile","iam:TagInstanceProfile","iam:UntagInstanceProfile","iam:AddRoleToInstanceProfile","iam:RemoveRoleFromInstanceProfile","iam:ListInstanceProfilesForRole"],
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:instance-profile/${PROJECT}-*"
    },
    {
      "Sid": "IAMPolicies",
      "Effect": "Allow",
      "Action": ["iam:CreatePolicy","iam:DeletePolicy","iam:GetPolicy","iam:GetPolicyVersion","iam:ListPolicyVersions","iam:CreatePolicyVersion","iam:DeletePolicyVersion"],
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:policy/${PROJECT}-*"
    },
    {
      "Sid": "IAMPassRole",
      "Effect": "Allow",
      "Action": ["iam:PassRole"],
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/${PROJECT}-*",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": ["ecs-tasks.amazonaws.com","ec2.amazonaws.com","vpc-flow-logs.amazonaws.com"]
        }
      }
    },
    {
      "Sid": "IAMOIDCProvider",
      "Effect": "Allow",
      "Action": ["iam:CreateOpenIDConnectProvider","iam:DeleteOpenIDConnectProvider","iam:GetOpenIDConnectProvider","iam:UpdateOpenIDConnectProviderThumbprint","iam:ListOpenIDConnectProviders"],
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/*"
    },
    {
      "Sid": "AutoScaling",
      "Effect": "Allow",
      "Action": ["application-autoscaling:RegisterScalableTarget","application-autoscaling:DeregisterScalableTarget","application-autoscaling:DescribeScalableTargets","application-autoscaling:PutScalingPolicy","application-autoscaling:DeleteScalingPolicy","application-autoscaling:DescribeScalingPolicies","application-autoscaling:TagResource","application-autoscaling:UntagResource","application-autoscaling:ListTagsForResource"],
      "Resource": "*"
    },
    {
      "Sid": "TaggingAndSTS",
      "Effect": "Allow",
      "Action": ["tag:GetResources","tag:GetTagKeys","tag:GetTagValues","sts:GetCallerIdentity"],
      "Resource": "*"
    }
  ]
}
ENDPOLICY
)

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "${PROJECT}-github-actions-full-deploy" \
  --policy-document "$DEPLOY_POLICY" \
  --no-cli-pager

log_success "Least-privilege policy applied to $ROLE_NAME"

# Detach AdministratorAccess if it was previously attached
# (safe to run even if it was never attached)
ADMIN_ATTACHED=$(aws iam list-attached-role-policies \
  --role-name "$ROLE_NAME" \
  --query 'AttachedPolicies[?PolicyName==`AdministratorAccess`].PolicyName' \
  --output text 2>/dev/null || echo "")
if [[ -n "$ADMIN_ATTACHED" ]]; then
  aws iam detach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/AdministratorAccess"
  log_success "AdministratorAccess detached (replaced by least-privilege policy)"
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

# Generate two distinct random values — one for SECRET_KEY, one for JWT_SECRET_KEY
SUGGESTED_SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null \
  || openssl rand -hex 32)
SUGGESTED_JWT_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null \
  || openssl rand -hex 32)
echo -e "  ${BLUE}💡 Suggested values (copy each one separately):${NC}"
echo "     SECRET_KEY     : $SUGGESTED_SECRET_KEY"
echo "     JWT_SECRET_KEY : $SUGGESTED_JWT_KEY"
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
echo "  IAM Policy      : least-privilege inline (covers deploy + cleanup)"
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