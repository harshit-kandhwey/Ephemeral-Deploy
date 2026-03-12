# 🔐 GitHub Secrets & Setup Guide

This document covers every secret and configuration needed to run the CI/CD pipeline.

---

## Required GitHub Secrets

Navigate to your repo → **Settings → Secrets and variables → Actions → New repository secret**

### AWS Authentication (OIDC - no permanent keys!)

| Secret Name           | Description                     | How to Get                   |
| --------------------- | ------------------------------- | ---------------------------- |
| `AWS_DEPLOY_ROLE_ARN` | IAM role ARN for GitHub Actions | Output from `make bootstrap` |

### Terraform Variables (passed as `TF_VAR_*`)

| Secret Name             | Description             | Example                                                    |
| ----------------------- | ----------------------- | ---------------------------------------------------------- |
| `TF_VAR_db_password`    | RDS PostgreSQL password | Use a strong random string                                 |
| `TF_VAR_app_secret_key` | Flask secret key        | `python -c "import secrets; print(secrets.token_hex(32))"` |
| `TF_VAR_jwt_secret_key` | JWT signing key         | `python -c "import secrets; print(secrets.token_hex(32))"` |

---

## GitHub Environment Configuration

For production deployments, configure **required reviewers**:

1. Go to **Settings → Environments → New environment**
2. Create: `dev`, `staging`, `prod`
3. For `prod`:
   - Enable **Required reviewers** (add yourself)
   - This creates a manual approval gate before `terraform apply` runs on prod

---

## One-Time Setup Steps

### Step 1: Configure AWS CLI locally

```bash
aws configure
# Enter: Access Key, Secret Key, Region (us-east-1), Output (json)
```

### Step 2: Run bootstrap (creates S3, DynamoDB, OIDC)

```bash
export GITHUB_ORG=your-github-username
export GITHUB_REPO=nexusdeploy
make bootstrap
```

### Step 3: Add GitHub Secrets

Copy the role ARN from bootstrap output and add all secrets listed above.

### Step 4: Update tfvars

Edit `terraform/environments/dev/terraform.tfvars`:

```hcl
github_org  = "your-actual-github-username"
github_repo = "nexusdeploy"
```

### Step 5: Push and watch it deploy

```bash
git push origin develop
# Watch GitHub Actions → you'll see: lint → test → build → plan → apply
```

---

## Understanding the OIDC Flow

```
GitHub Actions runner
        │
        │  1. Request JWT token from GitHub
        ▼
GitHub OIDC Provider
        │
        │  2. JWT contains: repo name, branch, workflow
        ▼
AWS STS AssumeRoleWithWebIdentity
        │
        │  3. Validates JWT against GitHub's public keys
        │  4. Checks: repo matches condition in role trust policy
        ▼
Temporary credentials (15min - 1hr)
        │
        │  5. Used for: ECR push, Terraform apply
        ▼
AWS Resources
```

**Why this matters for interviews:**

- No long-lived AWS keys stored in GitHub
- If GitHub is compromised, rotating is just updating the trust policy
- Credentials expire automatically
- Each workflow run gets fresh credentials

---

## Cost Tracking

Resources and their costs (us-east-1 on-demand pricing):

| Resource          | Type              | Cost       | Free Tier?       |
| ----------------- | ----------------- | ---------- | ---------------- |
| ECS Fargate (API) | 0.25 vCPU / 0.5GB | ~$0.01/hr  | No               |
| ECS Fargate SPOT  | 0.25 vCPU / 0.5GB | ~$0.003/hr | No               |
| RDS PostgreSQL    | db.t3.micro       | ~$0.017/hr | Yes (750 hrs/mo) |
| ElastiCache Redis | cache.t3.micro    | ~$0.017/hr | Yes (750 hrs/mo) |
| S3 state bucket   | < 1MB             | ~$0.00     | Yes              |
| DynamoDB lock     | PAY_PER_REQUEST   | ~$0.00     | Yes              |
| ECR storage       | < 500MB           | ~$0.00     | Yes (500MB/mo)   |
| CloudWatch logs   | 3-day retention   | ~$0.00     | Yes              |

**Total for a 30-minute dev run: ~$0.02**

The 30-minute auto-cleanup ensures dev environments never accumulate cost.

---

## Prod Manual Destroy

Production is not auto-destroyed. To destroy prod:

```bash
# 1. Download state file
make prod-state-download

# 2. Verify what will be destroyed
terraform plan -destroy -state=prod-terraform.tfstate

# 3. Destroy
terraform destroy -state=prod-terraform.tfstate
```
