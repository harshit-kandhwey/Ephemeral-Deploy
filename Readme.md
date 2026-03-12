# NexusDeploy - Production-Grade DevOps on AWS

A full-stack project management API deployed with a complete DevOps pipeline on AWS.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     GitHub Repository                        │
│                                                             │
│  feature/* → PR → ci.yml (lint + test + docker scan)       │
│  develop   → push → deploy.yml → staging                    │
│  main      → push → deploy.yml → prod (requires approval)   │
└──────────────────────┬──────────────────────────────────────┘
                       │ OIDC (no stored keys)
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                   AWS Account                                │
│                                                             │
│  ┌──────────────┐    ┌─────────────────────────────────┐   │
│  │  ECR         │    │  S3: nexusdeploy-terraform-state │   │
│  │  api:sha     │    │  ├── dev/terraform.tfstate        │   │
│  │  worker:sha  │    │  ├── staging/terraform.tfstate    │   │
│  └──────────────┘    │  └── prod/terraform.tfstate       │   │
│                      └─────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  VPC (10.0.0.0/16)                                  │   │
│  │                                                     │   │
│  │  Public Subnets         ← (ALB - commented out)     │   │
│  │                                                     │   │
│  │  Private App Subnets:                               │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────┐  │   │
│  │  │ ECS: API     │  │ ECS: Worker  │  │ECS: Beat │  │   │
│  │  │ Flask/Gunicorn│  │ Celery       │  │Scheduler │  │   │
│  │  │ FARGATE_SPOT  │  │ FARGATE_SPOT │  │          │  │   │
│  │  └──────────────┘  └──────────────┘  └──────────┘  │   │
│  │                                                     │   │
│  │  Private DB Subnets:     Private Cache Subnets:     │   │
│  │  ┌──────────────────┐    ┌──────────────────────┐   │   │
│  │  │ RDS PostgreSQL   │    │ ElastiCache Redis     │   │   │
│  │  │ db.t3.micro      │    │ cache.t3.micro        │   │   │
│  │  └──────────────────┘    └──────────────────────┘   │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  Secrets Manager  CloudWatch Logs  IAM (OIDC + task roles)  │
└─────────────────────────────────────────────────────────────┘
```

## Tech Stack

| Category        | Technology                                         |
| --------------- | -------------------------------------------------- |
| **API**         | Python / Flask / Gunicorn                          |
| **Database**    | PostgreSQL 15 (RDS)                                |
| **Cache/Queue** | Redis 7 (ElastiCache)                              |
| **Workers**     | Celery + Celery Beat                               |
| **Containers**  | Docker / ECS Fargate                               |
| **Registry**    | Amazon ECR                                         |
| **IaC**         | Terraform (modular)                                |
| **CI/CD**       | GitHub Actions                                     |
| **Auth**        | OIDC (no stored AWS keys)                          |
| **Secrets**     | AWS Secrets Manager                                |
| **Monitoring**  | CloudWatch + Prometheus metrics                    |
| **Security**    | VPC flow logs, Security groups, container scanning |

## Repository Structure

```
nexusdeploy/
├── app/                          # Application code
│   ├── src/
│   │   ├── api/v1/               # REST API endpoints
│   │   ├── models/               # SQLAlchemy models
│   │   ├── services/             # S3, Cache services
│   │   ├── tasks/                # Celery tasks
│   │   └── utils/                # Decorators, pagination
│   └── tests/                    # pytest suite
│
├── terraform/
│   ├── modules/                  # Reusable Terraform modules
│   │   ├── vpc/                  # VPC, subnets, NAT, flow logs
│   │   ├── ecs/                  # ECS cluster, services, autoscaling
│   │   ├── rds/                  # PostgreSQL RDS
│   │   ├── elasticache/          # Redis ElastiCache
│   │   ├── ecr/                  # Container registries + lifecycle
│   │   ├── iam/                  # OIDC, roles, least-privilege
│   │   └── security-groups/      # Network access rules
│   └── environments/
│       ├── dev/                  # Short-lived, auto-destroyed in 30m
│       ├── staging/              # Mirrors prod, auto-destroyed nightly
│       └── prod/                 # Long-lived, manual destroy only
│
├── .github/workflows/
│   ├── ci.yml                    # Lint → Test → Docker scan → TF validate
│   ├── deploy.yml                # Build → Push ECR → TF Plan → TF Apply
│   └── cleanup.yml               # Destroy env + ECR + S3 state
│
├── scripts/
│   ├── bootstrap.sh              # One-time AWS setup (S3, DynamoDB, OIDC)
│   └── cleanup.sh                # Tag-based fallback cleanup
│
├── Makefile                      # Developer workflow shortcuts
└── docs/
    └── SETUP.md                  # Setup guide and secrets documentation
```

## Key DevOps Concepts Demonstrated

### Infrastructure as Code

- Modular Terraform (vpc, ecs, rds, iam as separate reusable modules)
- Remote state in S3 with DynamoDB locking (prevents concurrent modifications)
- Per-environment `tfvars` files for config promotion
- `terraform plan` output posted as PR comments (GitOps review)

### CI/CD Pipeline

- **Lint stage**: flake8, black, isort, bandit (security), safety (CVE scan)
- **Test stage**: pytest with real PostgreSQL + Redis service containers
- **Build stage**: Docker multi-platform build with layer caching
- **Scan stage**: Trivy container vulnerability scanning
- **Deploy stage**: Terraform plan → manual approval (prod) → apply

### Security

- **OIDC authentication**: GitHub Actions assumes AWS role without stored credentials
- **Secrets Manager**: Secrets sourced from AWS Secrets Manager and securely injected as environment variables at ECS task runtime (prevents plaintext storage and repository commits)
- **Least-privilege IAM**: Separate execution role (pull images) vs task role (app perms)
- **Network isolation**: 4-tier subnet architecture (public/app/db/cache)
- **Security groups**: Strict per-service rules (workers can't receive inbound traffic)
- **VPC Flow Logs**: REJECT traffic logged for security auditing

### Cost Optimization

- `FARGATE_SPOT` for non-prod (70% cheaper than regular Fargate)
- Single NAT Gateway per environment (vs one per AZ)
- ECR lifecycle policies (keep last 3 images only)
- Short CloudWatch log retention (3 days dev, 7 days staging)
- **Auto-cleanup**: Non-prod environments destroyed after 30 minutes
- Free-tier sizing: `db.t3.micro`, `cache.t3.micro`

### Observability

- CloudWatch log groups per service (`/ecs/nexusdeploy/dev/api`)
- Prometheus metrics endpoint (`/metrics`) for scraping
- ECS container health checks (auto-restart unhealthy tasks)
- ECS deployment circuit breaker (auto-rollback failed deploys)

### Load Balancer (commented out, cost-saving)

Full ALB configuration exists in `terraform/modules/ecs/main.tf` - commented
with explanation. Demonstrates: HTTP→HTTPS redirect, target groups, health checks,
TLS termination, access logging.

## Getting Started

```bash
# 1. Clone and setup
git clone https://github.com/harshit-kandhwey/Ephemeral-Deploy.git
cd Ephemeral-Deploy

# 2. Local development
make up           # Start postgres + redis + api locally

# 3. Run tests
make test

# 4. Bootstrap AWS (one-time)
export GITHUB_ORG=your-username
make bootstrap    # Creates S3, DynamoDB, OIDC, IAM role

# 5. Add GitHub secrets (see docs/SETUP.md)

# 6. Push to develop → watch pipeline deploy to dev (auto-destroys in 30m)
git push origin develop
```

See [docs/SETUP.md](docs/SETUP.md) for full setup instructions.
