# Ephemeral Deploy — Production AWS DevOps Pipeline

> A containerised project management API deployed end-to-end on AWS, built to demonstrate a complete, production-grade DevOps pipeline. The application (REST API with teams, projects, tasks, users) exists as a realistic workload to operate — every engineering decision in this repository is an infrastructure or operational decision.
>
> **Naming note:** AWS resources (ECS clusters, ECR repos, S3 state bucket, SSM paths, IAM roles) are prefixed with `nexusdeploy` for tagging and identification inside AWS. The repository and project itself is called **Ephemeral Deploy**.

---

## Table of Contents

1. [What This Project Demonstrates](#1-what-this-project-demonstrates)
2. [How It All Fits Together](#2-how-it-all-fits-together)
3. [Repository Structure](#3-repository-structure)
4. [The Application Layer](#4-the-application-layer)
5. [Infrastructure — Terraform Modules](#5-infrastructure--terraform-modules)
6. [Networking — 4-Tier VPC](#6-networking--4-tier-vpc)
7. [Secrets Management](#7-secrets-management)
8. [CI/CD Pipeline](#8-cicd-pipeline)
9. [OIDC Authentication — No Stored AWS Keys](#9-oidc-authentication--no-stored-aws-keys)
10. [Blue-Green Deployment (prod)](#10-blue-green-deployment-prod)
11. [Auto-Cleanup — 45-Minute Dev TTL](#11-auto-cleanup--45-minute-dev-ttl)
12. [Monitoring Stack](#12-monitoring-stack)
13. [Cost Engineering](#13-cost-engineering)
14. [Commented-Out Features](#14-commented-out-features)
15. [Getting Started — First Deployment](#15-getting-started--first-deployment)
16. [Day-to-Day Operations (Makefile Reference)](#16-day-to-day-operations-makefile-reference)
17. [Local Development](#17-local-development)

---

## 1. What This Project Demonstrates

| Pillar                     | Implementation                                                                        |
| -------------------------- | ------------------------------------------------------------------------------------- |
| **Infrastructure as Code** | Modular Terraform, S3 remote state, per-environment isolation                         |
| **CI/CD**                  | GitHub Actions + OIDC — zero stored AWS credentials, multi-stage pipeline             |
| **Container Platform**     | ECS Fargate, ECR image lifecycle, FARGATE_SPOT cost optimisation                      |
| **Networking**             | 4-tier VPC, least-privilege security groups, VPC flow logs                            |
| **Secrets Management**     | SSM Parameter Store → Secrets Manager → ECS runtime injection                         |
| **Deployment Strategy**    | Blue-green with automated health checks, instant rollback, 24 h drain                 |
| **Observability**          | Prometheus + Grafana on EC2 + CloudWatch alarms + CloudWatch dashboard                |
| **Cost Engineering**       | 45-min ephemeral dev environments, Spot pricing, free-tier sizing                     |
| **Security Hardening**     | Non-root containers, Grype/Trivy scanning, least-privilege IAM, REJECT-only flow logs |

---

## 2. How It All Fits Together

### Branch → Environment Mapping

```
feature/** ──PR──▶  ci.yml   ──▶  lint + test + scan       (no AWS touched)
dev        ──push─▶ deploy.yml ─▶  dev environment          (auto-destroys in 45 min)
main       ──push─▶ deploy.yml ─▶  prod environment         (blue-green, manual destroy)
```

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  GitHub Actions                                                             │
│                                                                             │
│  ci.yml      ▶  lint ▶ pytest ▶ Grype container scan ▶ terraform validate │
│  deploy.yml  ▶  OIDC auth ▶ docker buildx ▶ ECR push ▶ terraform apply    │
│  cleanup.yml ▶  terraform destroy ▶ tag-based fallback ▶ S3 state wipe    │
└────────────────────────────────┬────────────────────────────────────────────┘
                                 │ OIDC (no long-lived keys)
┌────────────────────────────────▼────────────────────────────────────────────┐
│  AWS  (us-east-1)                                                           │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  VPC  10.0.0.0/16                                                    │   │
│  │                                                                      │   │
│  │  ── Tier 1: Public Subnets ────────────────────────────────────────  │   │
│  │  ┌────────────────────────────────────────────────────────────────┐  │   │
│  │  │  EC2  t3.micro  +  Elastic IP  (monitoring stack)              │  │   │
│  │  │  :9090 Prometheus   :3000 Grafana   :9100 Node Exporter        │  │   │
│  │  └────────────────────────────────────────────────────────────────┘  │   │
│  │  [ ALB lives here when enabled — see §14 Commented Features ]        │   │
│  │                                                                      │   │
│  │  ── Tier 2: Private App Subnets ───────────────────────────────────  │   │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌──────────────────┐      │   │
│  │  │  ECS: API       │  │  ECS: Worker    │  │  ECS: Beat       │      │   │
│  │  │  Flask/Gunicorn │  │  Celery         │  │  Celery Beat     │      │   │
│  │  │  FARGATE_SPOT   │  │  FARGATE_SPOT   │  │  Singleton       │      │   │
│  │  └─────────────────┘  └─────────────────┘  └──────────────────┘      │   │
│  │  prod: two complete sets of the above (slot1 + slot2)                │   │
│  │                                                                      │   │
│  │  ── Tier 3: Private DB Subnets ────────────────────────────────────  │   │
│  │  ┌────────────────────────────────────────────────────────────────┐  │   │
│  │  │  RDS PostgreSQL  db.t3.micro  (multi-AZ subnet group)          │  │   │
│  │  └────────────────────────────────────────────────────────────────┘  │   │
│  │                                                                      │   │
│  │  ── Tier 4: Private Cache Subnets ─────────────────────────────────  │   │
│  │  ┌────────────────────────────────────────────────────────────────┐  │   │
│  │  │  ElastiCache Redis  cache.t3.micro                             │  │   │
│  │  └────────────────────────────────────────────────────────────────┘  │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ECR  ·  SSM Parameter Store  ·  Secrets Manager  ·  CloudWatch  ·  S3     │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Repository Structure

```
ephemeral-deploy/
│
├── app/                              The workload — gives the infra something real to operate
│   ├── src/
│   │   ├── api/v1/                   REST endpoints: auth, users, teams, projects, tasks, comments
│   │   ├── models/                   SQLAlchemy models (User, Team, Project, Task, AuditLog)
│   │   ├── extensions.py             Flask extensions init (db, jwt, redis, celery)
│   │   ├── celery_worker.py          Celery app factory
│   │   └── init_db.py                DB schema creation + seed data script
│   ├── tests/                        77 tests (pytest + coverage)
│   ├── Dockerfile                    API image: Gunicorn, non-root user, 2 workers
│   ├── Dockerfile.worker             Worker image: Celery, non-root user, concurrency=2
│   └── pyproject.toml                black (120 line length) + isort (black profile)
│
├── terraform/
│   ├── modules/                      Reusable blueprints — never run directly
│   │   ├── vpc/                      VPC, subnets, IGW, NAT, route tables, flow logs, VPC endpoints
│   │   ├── ecs/                      ECS cluster, task defs (API+worker+beat), services, auto-scaling
│   │   ├── rds/                      PostgreSQL RDS, subnet group, parameter group
│   │   ├── elasticache/              Redis cluster, subnet group
│   │   ├── ecr/                      ECR repos, image lifecycle policy (keep last 3)
│   │   ├── iam/                      OIDC provider, GitHub Actions role, ECS execution/task roles
│   │   ├── security-groups/          Per-service least-privilege SGs (ALB, API, worker, RDS, Redis, monitoring)
│   │   └── monitoring/               EC2 monitoring stack, CloudWatch alarms, CloudWatch dashboard
│   │       └── files/                Prometheus config, Grafana datasources, dashboard JSON, SD script
│   └── environments/
│       ├── dev/                      Calls all modules with dev sizing; TTL tag triggers auto-cleanup
│       └── prod/                     Calls all modules with prod sizing; instantiates the slot1 + slot2 ECS sets
│
├── .github/workflows/
│   ├── ci.yml                        Lint · format · test · Grype scan · terraform validate
│   ├── deploy.yml                    OIDC · build · push · apply · blue-green orchestration
│   └── cleanup.yml                   terraform destroy · tag-based fallback · S3 state wipe
│
├── scripts/
│   ├── bootstrap.sh                  One-time: S3 bucket · OIDC provider · IAM role · SSM secrets
│   └── cleanup.sh                    14-step dependency-ordered tag-based resource deletion fallback
│
├── docs/
│   └── SETUP.md                      GitHub secrets guide · OIDC explanation · cost breakdown
│
├── Makefile                          Operational shortcuts (see §16)
└── docker-compose.yml                Local dev only: postgres + redis + api + worker + beat + redis-commander
```

---

## 4. The Application Layer

The application is a project management REST API. It is the **workload** — its purpose is to give the infrastructure something real to deploy, health-check, scale, and monitor. You wouldn't build this exact app for a portfolio; you run it to show what happens around it.

### API Surface

| Resource | Endpoints                                                                          | Auth                             |
| -------- | ---------------------------------------------------------------------------------- | -------------------------------- |
| Auth     | `POST /api/v1/auth/login`, `POST /api/v1/auth/refresh`, `POST /api/v1/auth/logout` | Public / Bearer                  |
| Users    | `GET/POST /api/v1/users`, `GET/PUT/DELETE /api/v1/users/:id`                       | Bearer + role                    |
| Teams    | `GET/POST /api/v1/teams`, `GET/PUT/DELETE /api/v1/teams/:id`                       | Bearer + role                    |
| Projects | `GET/POST /api/v1/projects`, `GET/PUT/DELETE /api/v1/projects/:id`                 | Bearer + role                    |
| Tasks    | `GET/POST /api/v1/tasks`, `GET/PUT/DELETE /api/v1/tasks/:id`                       | Bearer + role                    |
| Comments | `GET/POST /api/v1/tasks/:id/comments`                                              | Bearer                           |
| Health   | `GET /health`, `GET /ready`                                                        | Public                           |
| Metrics  | `GET /metrics`                                                                     | Public (Prometheus scrapes this) |
| Docs     | `GET /apidocs`                                                                     | Public (Swagger UI)              |

### Roles and Access Control

Three roles — `admin`, `manager`, `developer` — are enforced via a `@role_required` decorator on every mutating endpoint. Team membership gates data visibility: non-admins only see projects and tasks that belong to their team.

### Audit Logging

Every create/update/delete on any entity writes a record to the `audit_logs` table, storing `user_id`, `action`, `entity_type`, `entity_id`, and client IP. The IP is sourced from `request.remote_addr` — see the `_get_real_ip()` comment in `projects.py` for the ProxyFix note that applies when ALB is enabled.

### Background Tasks (Celery)

Three ECS services handle async work:

- **API** — Flask/Gunicorn, serves HTTP, exposes `/metrics`
- **Worker** — Celery worker, `concurrency=2`, processes tasks from Redis queue
- **Beat** — Celery Beat singleton, fires scheduled tasks on a cron-like schedule

All three share the same Docker image base, same environment variables, and same secrets from Secrets Manager. Beat is sized to `desired_count = 1` and never runs more than one instance (running multiple Beat schedulers causes duplicate task firing).

### Database Initialisation

`init_db.py` runs in three ordered steps:

1. **App DB user** — creates a least-privilege `nexusapp` PostgreSQL user (not the RDS superuser) that the API connects as at runtime.
2. **Schema** — `db.create_all()` via SQLAlchemy.
3. **Seed data** — demo users, teams, projects, tasks. In non-production environments, seed credentials are printed to stdout. In production, credentials come from `SEED_*_PASSWORD` env vars and nothing is printed.

---

## 5. Infrastructure — Terraform Modules

Terraform is split into **modules** (reusable blueprints) and **environments** (concrete instantiations). Modules have no idea which environment is calling them — they receive variables and produce resources. This means the same `vpc` module runs in dev with smaller CIDR ranges and in prod with flow logs and longer retention.

### Module Responsibilities

| Module            | What It Creates                                                                                                                                             |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `vpc`             | VPC, 4 subnet tiers across 2 AZs, IGW, optional NAT GW, route tables, VPC flow logs, VPC interface endpoints (ECR, S3, Secrets Manager, SSM)                |
| `ecs`             | ECS cluster, 3 task definitions (api/worker/beat), 3 ECS services, App Auto Scaling (CPU-based), CloudWatch log groups, optional ALB (commented out)        |
| `rds`             | PostgreSQL `db.t3.micro`, subnet group spanning private DB subnets, parameter group                                                                         |
| `elasticache`     | Redis `cache.t3.micro`, subnet group, cluster mode disabled (single node)                                                                                   |
| `ecr`             | Two ECR repos (`nexusdeploy-api-{env}`, `nexusdeploy-worker-{env}`), lifecycle policy keeping last 3 images per tag prefix                                  |
| `iam`             | GitHub OIDC provider (imported, not owned), GitHub Actions deploy role, ECS execution role, ECS task role, VPC flow log role                                |
| `security-groups` | One SG per service tier: ALB (commented out), API, worker, RDS, Redis, monitoring EC2                                                                       |
| `monitoring`      | EC2 t3.micro with Elastic IP, IAM instance role, monitoring config uploaded to S3, CloudWatch alarms (ECS CPU, RDS CPU, Redis memory), CloudWatch dashboard |

### Remote State

Terraform state lives in `s3://nexusdeploy-terraform-state` with per-environment keys:

```
s3://nexusdeploy-terraform-state/
  dev/terraform.tfstate
  prod/terraform.tfstate
  monitoring/config/          ← Prometheus + Grafana config files
```

State is encrypted at rest (S3 default encryption). Bucket versioning is disabled for this single-developer project — see §14 for how to add lifecycle policies and DynamoDB locking for team use.

### Provider Pinning

Both environments pin the AWS provider version:

- **dev**: `~> 5.0` — accepts any `5.x` patch update
- **prod**: `~> 5.40.0` — pinned to a specific minor version, updated deliberately after testing

This prevents a provider upgrade from changing prod behaviour on an unreviewed push.

---

## 6. Networking — 4-Tier VPC

The VPC uses a defence-in-depth layout. Each tier has its own subnet group and its own security group — traffic can only flow between tiers through explicitly defined rules.

```
┌──────────────────────────────────────────────────┐
│  Public Subnets (2 AZs)  10.0.0.0/24            │
│  IGW attached — monitoring EC2 lives here        │
│  ALB also lives here when enabled                │
└──────────────────────┬───────────────────────────┘
                       │ ECS tasks pull images from ECR
                       │ via VPC Interface Endpoints
┌──────────────────────▼───────────────────────────┐
│  Private App Subnets (2 AZs)  10.0.1.0/24       │
│  ECS Fargate tasks (API, Worker, Beat)           │
│  No inbound from internet                        │
└──────────┬────────────────────┬──────────────────┘
           │ port 5432          │ port 6379
┌──────────▼──────────┐  ┌─────▼────────────────────┐
│  Private DB Subnets │  │  Private Cache Subnets   │
│  10.0.2.0/24        │  │  10.0.3.0/24             │
│  RDS PostgreSQL      │  │  ElastiCache Redis       │
└─────────────────────┘  └──────────────────────────┘
```

### VPC Endpoints (replaces NAT Gateway in dev)

ECS tasks in private subnets need to reach AWS APIs to pull images from ECR and fetch secrets. Instead of routing that traffic through a NAT Gateway (which costs ~$1/day), the VPC module creates Interface Endpoints that let private subnets talk directly to AWS services over the AWS backbone:

- `ecr.api` — ECS authentication with ECR
- `ecr.dkr` — Docker image layer pulls
- `secretsmanager` — runtime secret injection
- `ssm` + `ssmmessages` + `ec2messages` — SSM Session Manager (used by `make shell`)
- `s3` (Gateway endpoint, free) — S3 access for monitoring config download

### VPC Flow Logs

Flow logs are enabled on the VPC, capturing **REJECT** traffic only (accepted traffic is not logged — that would be very noisy and expensive). Logs go to CloudWatch at `/aws/vpc/flowlogs/nexusdeploy-{env}`. Retention is 3 days in dev and 14 days in prod. Use this to diagnose security group misconfigurations and spot unexpected traffic patterns.

### Security Groups — Least Privilege

Every service has its own security group with the minimum possible rules:

| SG             | Inbound                                          | Outbound                                                                       |
| -------------- | ------------------------------------------------ | ------------------------------------------------------------------------------ |
| API            | Port 5000 from VPC CIDR (or ALB SG when enabled) | Port 5432 to RDS SG, port 6379 to Redis SG, port 443 to `0.0.0.0/0` (AWS APIs) |
| Worker         | None                                             | Port 5432 to RDS SG, port 6379 to Redis SG, port 443 to `0.0.0.0/0`            |
| RDS            | Port 5432 from API SG + Worker SG                | None                                                                           |
| Redis          | Port 6379 from API SG + Worker SG                | None                                                                           |
| Monitoring EC2 | Port 9090 + 3000 + 9100 from VPC CIDR            | Port 443 to `0.0.0.0/0`                                                        |

Workers have **zero inbound rules** — they only reach outward to Redis and PostgreSQL. This is intentional: Celery workers pull jobs from the broker; nothing needs to reach them.

---

## 7. Secrets Management

No secret is ever stored in a file, an environment variable in a Dockerfile, or a GitHub Secret (except the role ARN, which is not a secret).

### Flow: Bootstrap → SSM → Secrets Manager → ECS

```
1.  bootstrap.sh (one-time, interactive)
    └─▶ Prompts for each value
    └─▶ Stores in SSM Parameter Store as SecureString (KMS encrypted)
        /nexusdeploy/{env}/db/master_password
        /nexusdeploy/{env}/db/app_password
        /nexusdeploy/{env}/app/secret_key
        /nexusdeploy/{env}/app/jwt_secret_key
        /nexusdeploy/{env}/monitoring/grafana_password

2.  terraform apply
    └─▶ Reads values from SSM via data.aws_ssm_parameter
    └─▶ Creates aws_secretsmanager_secret with all runtime secrets
    └─▶ ECS task definitions reference the secret ARN with field selectors

3.  ECS task startup
    └─▶ ECS execution role pulls secrets from Secrets Manager
    └─▶ Injects as environment variables into the container at runtime
    └─▶ The application container never needs AWS credentials
```

The application connects to PostgreSQL as a **least-privilege app user** (`nexusapp`), not the RDS master user. `init_db.py` creates this user during first-run initialisation.

---

## 8. CI/CD Pipeline

Three workflow files handle all pipeline logic.

### `ci.yml` — Runs on every push and pull request

```
Job 0: detect-changes
  └── Diffs HEAD~1 to decide which jobs actually need to run
      (app changed? → run lint/test/docker. infra changed? → run terraform validate)

Job 1: lint  (runs if app changed)
  ├── black  ──write mode──▶  auto-formats code
  ├── isort  ──write mode──▶  auto-sorts imports
  ├── Commits formatting changes back with [skip ci] tag
  └── flake8 + bandit  ──check mode──▶  fails on violations

Job 2: test  (runs if app changed, after lint)
  ├── PostgreSQL 15 + Redis 7 as GitHub Actions service containers
  ├── pytest with --cov (fails if coverage < 60%)
  └── Uploads coverage report to Codecov (non-blocking)

Job 3: docker-build  (runs parallel to test, if app changed)
  ├── docker buildx build  (linux/amd64, GitHub Actions layer cache)
  ├── Grype container vulnerability scan
  │   ├── exit-code: 0  ──▶  non-blocking (shows findings, never fails the build)
  │   ├── severity: CRITICAL  ──▶  only critical findings reported
  │   └── Results uploaded to GitHub Security tab as SARIF
  └── Image not pushed (CI only — no AWS credentials in CI workflow)

Job 4: terraform-lint  (runs if infra changed, parallel to all app jobs)
  ├── terraform fmt -check -recursive
  ├── tflint  (non-blocking — shows awareness)
  └── terraform init -backend=false + terraform validate for each environment

Job 5: ci-summary
  ├── Gate job — fails if any upstream job failed. Blocks PR merge.
  └── Triggers the deploy pipeline
```

**Auto-formatting:** black and isort run in write mode. If they change anything, the bot commits back with `[skip ci]` to avoid a loop. This means formatting is never a reason for a CI failure — it's just fixed automatically.

### `deploy.yml` — Triggered by CI Pipeline on `dev` or `main` branches

```
Job 1: setup
  └── Determines: environment (dev/prod), Terraform action (apply/destroy), git SHA

Job 2: build  (uses OIDC to authenticate, always before deploy)
  ├── Configure AWS credentials via OIDC (no stored keys)
  ├── Login to ECR
  ├── docker buildx build (linux/amd64, layer cache from GitHub Actions)
  └── Push two images:
      nexusdeploy-api-{env}:{sha}
      nexusdeploy-api-{env}:latest
      nexusdeploy-worker-{env}:{sha}
      nexusdeploy-worker-{env}:latest

Job 3a: deploy-dev  (only on dev branch push)
  ├── terraform init  (-backend-config flags, no hardcoded values in code)
  ├── terraform apply (TF_VAR_api_image + TF_VAR_worker_image from build job)
  ├── Posts Grafana URL + Prometheus URL to Actions job summary
  └── Dispatches cleanup.yml with delay_minutes=30

Job 3b: deploy-prod  (only on main branch push)
  ├── terraform init
  ├── Read active_slot from SSM  (/nexusdeploy/prod/deployment/active_slot)
  ├── terraform apply targeting inactive slot only
  ├── Health check loop: poll ECS runningCount every 30s for up to 5 minutes
  │   PASS ──▶  Update SSM active_slot to new slot
  │             Store previous image tags in SSM for rollback reference
  │             Dispatch cleanup.yml with delay_minutes=1440 (24h) to drain old slot
  │   FAIL ──▶  Scale failed slot desired_count to 0 immediately
  │             SSM active_slot unchanged → old slot continues serving
  │             Zero user impact. Next push retries to same inactive slot.
```

### `cleanup.yml` — Scheduled destruction

```
Step 1: terraform destroy  (clean path — uses state file)
Step 2: cleanup.sh fallback  (if terraform destroy fails for any reason)
         14-step dependency-ordered tag-based deletion
Step 3: Delete S3 state file
         aws s3 rm s3://nexusdeploy-terraform-state/{env}/terraform.tfstate
         Prevents orphaned state confusing future deployments
```

A nightly GitHub Actions cron also runs cleanup against any forgotten dev environments (useful if a dev deploy ran and the 45-min dispatch was missed).

---

## 9. OIDC Authentication — No Stored AWS Keys

The pipeline never stores AWS credentials anywhere. Instead, GitHub Actions proves its identity to AWS using a short-lived JWT.

```
Step 1  GitHub Actions runner requests a JWT from:
        https://token.actions.githubusercontent.com

Step 2  JWT payload contains:
        - repository:  your-org/ephemeral-deploy
        - ref:         refs/heads/dev  (or main)
        - workflow:    deploy.yml
        - run_id:      unique per run

Step 3  deploy.yml calls the configure-aws-credentials action
        which calls aws sts AssumeRoleWithWebIdentity

Step 4  AWS validates the JWT signature against GitHub's published public keys
        and checks the IAM role's trust policy conditions:
          StringEquals  token.actions.githubusercontent.com:aud  →  sts.amazonaws.com
          StringLike    token.actions.githubusercontent.com:sub  →  repo:org/ephemeral-deploy:ref:refs/heads/dev

Step 5  AWS issues temporary credentials valid for 1 hour
        (expire automatically when the job ends, never stored anywhere)

Step 6  Credentials used for ECR login + terraform apply
        The role ARN itself (not a secret, just an identifier) is the only
        thing stored in GitHub Secrets: AWS_DEPLOY_ROLE_ARN
```

The IAM role has a least-privilege inline policy maintained in `bootstrap.sh`. It covers the exact set of actions needed for ECS deploy, Terraform resource management, SSM access, and cleanup — nothing more.

---

## 10. Blue-Green Deployment (prod)

Prod uses a Terraform-native blue-green strategy. Two complete sets of ECS services — the slots, named `-slot1` and `-slot2` — are defined in Terraform. The inactive slot runs at `desired_count = 0` — it costs nothing while standing by. (Blue-green is the *strategy*; the slots themselves are positional, since whichever one is live alternates on every deploy.)

### Deployment Flow

```
State before deploy:
  slot1  desired=1  running=1  ← ACTIVE (serving traffic)
  slot2  desired=0  running=0  ← IDLE

Push to main:
  slot1  desired=1  running=1  ← unchanged, traffic unaffected
  slot2  desired=1  running=1  ← new image deployed to inactive slot

Health check loop (every 30s, max 5 minutes):
  Polls:  aws ecs describe-services  for slot2.runningCount == slot2.desiredCount

If health check PASSES:
  ├── SSM  /nexusdeploy/prod/deployment/active_slot  ←  "slot2"
  ├── Previous image tags stored in SSM for rollback reference
  └── cleanup.yml dispatched with delay=1440min (24h) to drain slot1

  After 24h:
  slot1  desired=0  running=0  ← drained, idle for next cycle
  slot2  desired=1  running=1  ← active

If health check FAILS (or terraform apply itself fails):
  ├── slot2 scaled to desired=0 immediately
  ├── SSM active_slot unchanged → slot1 keeps serving
  └── Next push targets slot2 again — no manual intervention needed
```

### Slot Tracking

The active slot is tracked in SSM Parameter Store at:

```
/nexusdeploy/prod/deployment/active_slot   →   "slot1" or "slot2"
```

Terraform reads this at plan time to determine which slot gets the new image. The SSM value has `lifecycle { ignore_changes = [value] }` — Terraform creates it on first apply but never overwrites it after that. Only `deploy.yml` writes to it (after a confirmed healthy deploy).

To check the current active slot manually:

```bash
make prod-active-slot
```

### Why Not CodeDeploy?

The deployment controller is set to `type = "ECS"` (Terraform-managed). The alternative is `type = "CODE_DEPLOY"` — which provides AWS-console visibility, gradual traffic shifting via ALB listener weights, and approval gates between shift steps. To enable it, ALB must be enabled first (see §14). The current approach is simpler, fully understood, and demonstrates the same concepts without the additional AWS service dependency.

---

## 11. Auto-Cleanup — 45-Minute Dev TTL

Dev environments are designed to be thrown away. Every push to `dev` deploys a fresh environment and schedules its own destruction 45 minutes later via `cleanup.yml`.

### Why 45 minutes?

That's enough time to manually test the deployment, check Grafana, and hit the API. After that, the environment costs nothing because it no longer exists. You can always push to `dev` again to spin it back up in ~8 minutes.

### What the cleanup does

```
Step 1: terraform destroy  (preferred — uses state, clean and complete)

Step 2: If terraform destroy fails for any reason, cleanup.sh runs
        with tag-based resource deletion in strict dependency order:

   1.  ECS services          scale to 0, wait, deregister
   2.  ECR images            delete all untagged + old images
   3.  RDS instance          disable deletion protection, then delete
                             with no final snapshot (waits only if the
                             delete was actually accepted)
   4.  ElastiCache cluster   delete
   5.  Secrets Manager       force-delete (no recovery window)
   6.  Security groups       delete
   7.  NAT Gateway           release Elastic IP
   8.  Internet Gateway      detach + delete
   9.  Subnets               delete all 8
  10.  Route tables          delete
  11.  VPC                   delete
  12.  CloudWatch log groups  delete
  13.  IAM roles + policies   detach + delete
  14.  Verify                 aws resourcegroupstaggingapi confirms 0 tagged resources

Step 3: Delete S3 state file
        Prevents orphaned state from blocking the next deploy
```

### Dry run

```bash
make cleanup-dry ENV=dev   # shows what would be deleted without deleting anything
```

### Destroying prod

Prod is not ephemeral, and its RDS instance carries two protections that dev and staging don't (`terraform/modules/rds/main.tf`):

| Setting                   | dev / staging | prod                       |
| ------------------------- | ------------- | -------------------------- |
| `deletion_protection`     | `false`       | `true`                     |
| `skip_final_snapshot`     | `true`        | `false` (takes a snapshot) |
| `recovery_window_in_days` | `0` (secrets) | `7` (secrets)              |

These change how a teardown behaves:

- **Deletion protection is not cleared by Terraform.** `terraform destroy` fails outright against a protected instance. `cleanup.sh` now detects this and disables protection before deleting.
- **The final snapshot needs IAM permissions.** The deploy role is granted `rds:CreateDBSnapshot` / `DeleteDBSnapshot` / `DescribeDBSnapshots` (`bootstrap.sh` and `modules/iam`) — without them the destroy fails with `AccessDenied` on `rds:CreateDBSnapshot`. If you bootstrapped before these were added, re-run `ENV=prod ./scripts/bootstrap.sh` to refresh the policy.
- **Secrets survive a destroy for 7 days.** With a recovery window, AWS keeps the secret _name_ reserved even after deletion, so a redeploy inside that window fails on both create and import. The deploy workflow calls `restore-secret` before importing, so a prod rebuild works without waiting out the window. To free the names immediately instead: `aws secretsmanager delete-secret --secret-id <name> --force-delete-without-recovery`.

Prod destroy runs through the same workflow, but the job is bound to the `prod` GitHub environment, so it **blocks on manual approval**:

```bash
gh workflow run cleanup.yml --ref main -f environment=prod -f action=destroy -f delay_minutes=0
```

`make tf-destroy ENV=prod` is deliberately blocked — the approval gate is the intended control.

---

## 12. Monitoring Stack

Two monitoring approaches run simultaneously and are both available as datasources in the same Grafana dashboard. This is intentional — it shows knowledge of both the pull-based (Prometheus) and managed (CloudWatch) models.

### Prometheus + Grafana on EC2 t3.micro

Everything is installed and configured at EC2 boot time via `monitoring-userdata.sh.tpl`. No manual setup is needed after `terraform apply`.

| Component           | Port | Role                                                  |
| ------------------- | ---- | ----------------------------------------------------- |
| Prometheus          | 9090 | Scrapes Flask `/metrics` on ECS tasks every 15s       |
| Grafana             | 3000 | Visualises Prometheus + CloudWatch in one dashboard   |
| Node Exporter       | 9100 | System metrics for the monitoring EC2 itself          |
| CloudWatch Exporter | 9106 | Bridges CloudWatch ECS metrics into Prometheus format |

**ECS service discovery** works via a shell script (`ecs-sd.sh`) running on a 60-second cron. It calls `aws ecs list-tasks` + `describe-tasks` to find the private IPs of running API tasks and writes a Prometheus `file_sd` targets JSON. Prometheus reads this file and updates its scrape targets without a restart. The EC2's IAM role has `ecs:ListTasks` + `ecs:DescribeTasks` for this purpose.

**Grafana auto-provisioning**: datasource configs (`grafana-datasources.yml`) and the dashboard JSON are stored in S3 (alongside Terraform state) and downloaded by the EC2 at boot. Grafana reads from `/etc/grafana/provisioning/` on startup — no manual dashboard import needed.

**Monitoring configs in S3**: The user_data script has a 16 KB size limit. All config files (prometheus.yml, cloudwatch-exporter.yml, grafana configs, dashboard JSON) are stored as S3 objects under `s3://nexusdeploy-terraform-state/monitoring/config/` and downloaded at boot. This keeps user_data small and makes config updates easy without reprovisioning the EC2.

**Pre-built Grafana dashboard panels:**

- HTTP request rate (req/s)
- p50 / p95 / p99 latency (histograms from Flask `/metrics`)
- 5xx error rate
- ECS running task count (from CloudWatch)
- RDS CPU + connection count
- Redis memory usage percentage

### CloudWatch (always on, AWS-native)

| What          | Detail                                                                                                                                 |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Log groups    | `/ecs/nexusdeploy/{env}/api` · `/ecs/nexusdeploy/{env}/worker` · `/ecs/nexusdeploy/{env}/beat` · `/aws/vpc/flowlogs/nexusdeploy-{env}` |
| Retention     | 3 days (dev) · 7 days (prod)                                                                                                           |
| Dashboard     | Provisioned by Terraform — ECS CPU, RDS CPU, Redis memory, error log Insights query                                                    |
| Alarms        | ECS API CPU > 80% for 4 min · RDS CPU > 75% · Redis memory > 80%                                                                       |
| VPC flow logs | REJECT-only — routed to CloudWatch for security auditing                                                                               |

### Accessing monitoring

After a deploy, `deploy.yml` prints the Grafana and Prometheus URLs to the Actions job summary. Or:

```bash
make monitoring-url ENV=prod      # prints Grafana URL from Terraform output
make monitoring-logs ENV=prod     # tails the EC2 setup log via SSM Session Manager
```

---

## 13. Cost Engineering

Every sizing and configuration decision is deliberate. Nothing is over-provisioned.

| Resource           | Configuration                      | Why                                                 | Cost                    |
| ------------------ | ---------------------------------- | --------------------------------------------------- | ----------------------- |
| ECS Fargate (dev)  | FARGATE_SPOT, 256 CPU / 512 MB     | Spot = 70% cheaper; dev tolerates interruption      | ~$0.02 per 45-min run   |
| ECS Fargate (prod) | FARGATE on-demand, same size       | On-demand required for prod reliability             | ~$0.05/hr while running |
| RDS                | db.t3.micro, 20 GB                 | Free tier                                           | Free (750 hrs/month)    |
| ElastiCache        | cache.t3.micro                     | Free tier                                           | Free (750 hrs/month)    |
| Monitoring EC2     | t3.micro + Elastic IP              | Free tier                                           | Free (750 hrs/month)    |
| NAT Gateway        | Disabled in dev, single GW in prod | $0.045/hr + data; VPC endpoints used instead in dev | $0 dev · ~$33/mo prod   |
| ECR lifecycle      | Keep last 3 images                 | Prevents unbounded storage growth                   | <$0.01/month            |
| Log retention      | 3d dev · 7d prod                   | CloudWatch storage costs $0.03/GB/month             | Negligible              |
| **Total dev run**  |                                    |                                                     | **~$0.02**              |

**Fargate Spot** — in dev, ECS services use the `FARGATE_SPOT` capacity provider. Spot capacity is unused Fargate capacity sold at a ~70% discount. AWS can reclaim it with a 2-minute notice. Dev environments tolerate this; prod uses on-demand.

**Auto Scaling** — the API ECS service has an App Auto Scaling policy targeting 70% CPU utilisation, with scale-out cooldown of 60s and scale-in of 300s. Min capacity equals the `api_desired_count` variable. This is always configured — even in dev — to show the pattern.

---

## 14. Commented-Out Features

These features are **fully implemented** in the codebase. They are commented out only because they cost money during demo use. Each can be enabled with a small, targeted change — the code is ready.

---

### Application Load Balancer + HTTPS

**Files:** `terraform/modules/ecs/main.tf` · `terraform/modules/security-groups/main.tf`

The complete ALB stack is written and commented:

- `aws_lb` — internet-facing, deletion protection in prod, access logs to S3
- `aws_lb_target_group` — IP mode (required for Fargate), `/health` check, 2 healthy / 3 unhealthy thresholds
- `aws_lb_listener` HTTP :80 — uses `dynamic` block to redirect to HTTPS in prod and forward in non-prod
- `aws_lb_listener` HTTPS :443 — TLS 1.3 security policy, ACM certificate
- `aws_security_group.alb` — :80/:443 from `0.0.0.0/0`, egress scoped to API SG only
- ECS service `load_balancer {}` block — wires API containers to the target group on port 5000
- API SG note — shows how to switch from VPC CIDR to `security_groups = [alb_sg_id]`

**To enable:**

1. Uncomment ALB blocks in `terraform/modules/ecs/main.tf` and `terraform/modules/security-groups/main.tf`
2. Add `acm_certificate_arn` and `alb_logs_bucket` to your environment's `terraform.tfvars`

**Cost when enabled:** ~$16/month for the ALB.

---

### DynamoDB State Locking

**Files:** `scripts/bootstrap.sh` · `terraform/environments/*/main.tf` · `.github/workflows/deploy.yml`

Terraform state locking prevents two concurrent `terraform apply` runs from corrupting the state file. It's disabled because this is a single-developer project — concurrent state writes cannot happen.

**To enable (3 steps):**

1. Uncomment the `aws dynamodb create-table` block in `bootstrap.sh` and re-run `make bootstrap`
2. Add `dynamodb_table = "nexusdeploy-terraform-locks"` to the `backend "s3"` block in `dev/main.tf` and `prod/main.tf`
3. Uncomment `TF_LOCK_TABLE: nexusdeploy-terraform-locks` in `deploy.yml`

**Cost when enabled:** $0 — DynamoDB PAY_PER_REQUEST at this scale is negligible.

---

### S3 State Bucket Hardening

**File:** `scripts/bootstrap.sh`

Two blocks are commented out with `log_warn` annotations explaining why:

- **Explicit AES256 SSE** via `aws s3api put-bucket-encryption` — S3 default encryption now covers this automatically, but an explicit configuration demonstrates intentional security posture
- **Lifecycle policy** via `aws s3api put-bucket-lifecycle-configuration` — transitions non-current state versions to `STANDARD_IA` after 30 days, expires after 90 days. Keeps the state bucket lean as deployment history accumulates

**To enable:** uncomment the two blocks in `bootstrap.sh` and re-run `make bootstrap`. Idempotent.

---

### NAT Gateway (dev)

**File:** `terraform/environments/dev/main.tf` — `enable_nat_gateway = false`

Private ECS tasks in dev reach AWS APIs through VPC Interface Endpoints (cheaper). Outbound internet access from private subnets is **not** available in dev without a NAT Gateway.

**To enable:** set `enable_nat_gateway = true` in `terraform/environments/dev/terraform.tfvars`.

**Cost when enabled:** ~$32/month ($0.045/hr + data transfer).

---

### NAT Gateway per AZ (prod high availability)

**File:** `terraform/modules/vpc/main.tf` — `aws_nat_gateway` resource

A single NAT Gateway is a single point of failure. If its AZ goes down, all private subnet outbound traffic fails. The comment documents the fix.

**To enable:** change `count = var.enable_nat_gateway ? 1 : 0` to `count = var.enable_nat_gateway ? length(var.availability_zones) : 0` on both `aws_eip.nat` and `aws_nat_gateway.main`, and update route table associations to use the AZ-local gateway.

**Cost per additional AZ:** ~$32/month.

---

### ECS Container Insights (dev)

**File:** `terraform/modules/ecs/main.tf` — `containerInsights` setting on the cluster

Container Insights is enabled in prod and disabled in dev via a ternary:

```hcl
value = var.environment == "prod" ? "enabled" : "disabled"
```

Container Insights publishes per-container CPU, memory, network, and storage metrics at higher resolution than default ECS metrics.

**To enable in dev:** change the condition to `"enabled"`.

**Cost when enabled:** ~$0.35 per container per month.

---

### CodeDeploy Deployment Controller

**File:** `terraform/modules/ecs/main.tf` — `deployment_controller` block

```hcl
deployment_controller {
  type = "ECS"
  # For AWS-managed blue/green: type = "CODE_DEPLOY"
}
```

`CODE_DEPLOY` integrates with ALB listener rule weights for gradual traffic shifting (10% → 50% → 100%), provides a deployment timeline in the CodeDeploy console, and supports approval gates. Requires ALB to be enabled first.

---

### ProxyFix / Real Client IP

**File:** `app/src/api/v1/projects.py` — `_get_real_ip()` function

When ALB is enabled, the `X-Forwarded-For` header carries the real client IP. The comment documents how to enable ProxyFix in `app.py` so `request.remote_addr` is set correctly without manual header parsing (which is an IP spoofing risk if done incorrectly).

---

## 15. Getting Started — First Deployment

### Prerequisites

- AWS CLI configured (`aws configure`) with an IAM user that has permissions to create S3, IAM, OIDC providers
- Docker Desktop running locally
- Terraform 1.7+ installed
- Git Bash or WSL (Windows users)

---

### Pre-flight checklist — what must be set before each push

| #   | What                                                                                          | Where to set                                                                 | dev | prod |
| --- | --------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- | :-: | :--: |
| 1   | `AWS_DEPLOY_ROLE_ARN` — IAM role ARN output by bootstrap                                      | GitHub → Settings → Secrets and variables → Actions → **Repository secrets** | ✅  |  ✅  |
| 2   | `dev` GitHub Environment (no approval gate)                                                   | GitHub → Settings → **Environments** → New environment                       | ✅  |  —   |
| 3   | `prod` GitHub Environment (Required reviewers enabled)                                        | GitHub → Settings → **Environments** → New environment                       |  —  |  ✅  |
| 4   | `MONITORING_ALLOWED_CIDR` — CIDR(s) allowed inbound to Grafana (:3000) and Prometheus (:9090) | GitHub → Settings → Environments → **prod** → Variables → New variable       |  —  |  ✅  |
| 5   | SSM Parameter Store secrets (DB passwords, JWT key, Grafana password)                         | Run `make bootstrap` once — prompts you interactively                        | ✅  |  ✅  |
| 6   | `github_org` + `github_repo` set in tfvars                                                    | `terraform/environments/dev/terraform.tfvars` and `prod/terraform.tfvars`    | ✅  |  ✅  |

**Notes on `MONITORING_ALLOWED_CIDR`:**

- Format: a JSON list of CIDR strings, e.g. `["203.0.113.42/32"]` or `["10.0.0.0/8","203.0.113.0/24"]`
- Set to your home/office IP or VPN egress CIDR — this is the only address that can reach Grafana and Prometheus in prod
- dev ignores this variable (dev hardcodes `0.0.0.0/0` — ephemeral environments, acceptable)
- Never commit a real CIDR to the repo; it lives only in the GitHub Environment variable

---

### Step 1: Bootstrap AWS infrastructure (one time only)

```bash
export GITHUB_ORG=your-github-username
export GITHUB_REPO=ephemeral-deploy
make bootstrap
```

`bootstrap.sh` creates:

- S3 bucket for Terraform state (versioned, encrypted, public access blocked)
- GitHub OIDC provider in AWS IAM (so GitHub Actions can assume roles without stored keys)
- IAM role `nexusdeploy-github-actions-deploy` with a least-privilege inline policy (the `nexusdeploy` prefix is the AWS resource naming convention used throughout this project)
- All SSM Parameter Store secrets (you are prompted interactively — nothing is written to disk)

The script is **idempotent** — safe to re-run. It skips anything that already exists.

### Step 2: Add the repository secret

```
Repository → Settings → Secrets and variables → Actions → New repository secret
Name:   AWS_DEPLOY_ROLE_ARN
Value:  (ARN printed at the end of bootstrap output)
```

### Step 3: Create GitHub Environments

```
Repository → Settings → Environments
Create:  dev   (no protection rules needed)
Create:  prod  (enable "Required reviewers" — add yourself)
```

### Step 4: Add the prod environment variable

```
Repository → Settings → Environments → prod → Variables → New variable
Name:   MONITORING_ALLOWED_CIDR
Value:  ["your.ip.address/32"]
```

Replace `your.ip.address` with your actual IP or VPN egress CIDR. This controls which addresses can reach Grafana (:3000) and Prometheus (:9090) in production.

### Step 5: Update tfvars

Edit both files:

```
terraform/environments/dev/terraform.tfvars
terraform/environments/prod/terraform.tfvars
```

Set `github_org` to your GitHub username and `github_repo` to your exact repo name.

### Step 6: Push to dev

```bash
git push origin dev
```

Watch GitHub Actions: `lint → test → docker-build → terraform-validate → build → deploy-dev`. After ~8 minutes, the Grafana and API URLs appear in the Actions job summary. The environment auto-destroys in 45 minutes.

### Step 7: Deploy to prod

```bash
git push origin main
```

Same pipeline, but `deploy-prod` runs blue-green logic instead of a simple apply. The prod environment requires manual approval from a required reviewer before the deploy job starts.

---

## 16. Day-to-Day Operations (Makefile Reference)

Run `make help` to see all targets. Commonly used:

```bash
# Local development
make up                       # Start docker-compose (postgres + redis + api + worker + beat)
make down                     # Stop and remove volumes
make test                     # Run pytest with coverage report
make lint                     # flake8 + black check + bandit

# Docker
make build                    # Build API and worker images locally
make push                     # Tag + push to ECR (requires ecr-login)

# Terraform
make tf-init  ENV=dev         # Init backend with correct bucket/key
make tf-plan  ENV=dev         # Plan changes
make tf-apply ENV=dev         # Apply (full deploy: build + push + apply)
make tf-destroy ENV=dev       # Destroy dev (blocked for prod)

# Operations
make status  ENV=dev          # Show ECS service running/desired counts
make logs    ENV=dev          # Tail CloudWatch logs for API service
make shell   ENV=dev          # ECS Exec into a running API container (no SSH needed)
make cleanup ENV=dev          # Run tag-based cleanup script manually

# Monitoring
make monitoring-url ENV=prod  # Print Grafana URL from Terraform output
make monitoring-logs ENV=dev  # Tail the monitoring EC2 setup log via SSM

# Prod blue-green
make prod-active-slot         # Print current active slot (slot1 or slot2)
make prod-state-download      # Download prod state file for local destroy

# Secrets
make secrets ENV=dev          # Re-run SSM secret creation for an environment
```

**Windows note:** `make` is not natively available in Command Prompt or PowerShell. Use Git Bash or WSL. Run Makefile targets as `bash -c "make <target>"` or `wsl make <target>` if needed.

---

## 17. Local Development

The Docker Compose stack runs the full application locally — no AWS account needed for development.

```bash
make up
```

This starts:

| Service         | Port | Purpose                                           |
| --------------- | ---- | ------------------------------------------------- |
| postgres        | 5432 | PostgreSQL 15 (persisted in Docker volume)        |
| redis           | 6379 | Redis 7 (used by Celery + API session cache)      |
| api             | 5000 | Flask API + Swagger UI at `/apidocs`              |
| worker          | —    | Celery worker (connects to same postgres + redis) |
| beat            | —    | Celery Beat scheduler                             |
| redis-commander | 8081 | Redis UI for inspecting queues                    |

The `app/` directory is volume-mounted into the API container. Code changes take effect after `docker compose restart api` — no rebuild needed.

### Initialise the database

```bash
docker compose exec api python -m src.init_db
```

This creates the schema and seeds demo data. In dev mode, it prints credentials to stdout:

```
Admin:      admin      / <generated>
Manager:    manager    / <generated>
Developer1: developer1 / <generated>
Developer2: developer2 / <generated>
```

### Try the API

```bash
# Get a token
curl -X POST http://localhost:5000/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username": "admin", "password": "<password from seed output>"}'

# Use the token
curl http://localhost:5000/api/v1/projects \
  -H "Authorization: Bearer <token>"
```

Or open `http://localhost:5000/apidocs` — Swagger UI with the Authorize button for JWT.

### Running tests

```bash
make test
# or directly:
cd app && pytest tests/ -v --cov=src --cov-report=term-missing
```

Tests use an in-memory SQLite database and a mocked Redis client — no running services needed. Coverage report is generated at `app/htmlcov/index.html`.

---

## Notes for Interviewers

Every feature in this repository has an intentional reason behind it:

- **OIDC instead of access keys** — demonstrates modern, keyless CI/CD security
- **FARGATE_SPOT in dev** — shows cost awareness, not just "make it work"
- **Blue-green with SSM slot tracking** — shows deployment strategy depth without requiring CodeDeploy
- **VPC endpoints instead of NAT GW in dev** — $0 vs $32/month for the same functional result
- **ECR lifecycle policy** — prevents unbounded image accumulation, something often forgotten
- **REJECT-only flow logs** — shows you understand the cost/signal tradeoff vs full logging
- **Auto-format with commit-back** — pragmatic CI design; shifts from blocking-on-format to self-healing
- **Modular Terraform** — environments call modules; modules are unaware of environments
- **Commented-out features with documentation** — shows you built them and made a deliberate cost-vs-value decision, not that you didn't know how

The application (teams, projects, tasks) is intentionally simple. The infrastructure around it is not.
