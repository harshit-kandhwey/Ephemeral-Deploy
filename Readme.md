# NexusDeploy — Production AWS DevOps Pipeline

A containerised web API deployed on AWS with a complete, production-grade DevOps pipeline.  
The application itself is a project management API — it exists as a realistic workload to operate. **Every engineering decision in this repository is an infrastructure or operational decision.**

---

## Core Infrastructure Skills Demonstrated

| Pillar                 | Implementation                                                             |
| ---------------------- | -------------------------------------------------------------------------- |
| Infrastructure as Code | Modular Terraform, S3 remote state, per-environment isolation              |
| CI/CD                  | GitHub Actions + OIDC — zero stored AWS credentials, multi-stage pipeline  |
| Container Platform     | ECS Fargate, ECR image lifecycle, FARGATE_SPOT cost optimisation           |
| Networking             | 4-tier VPC, least-privilege security groups, VPC flow logs                 |
| Secrets Management     | SSM Parameter Store → Secrets Manager → ECS runtime injection              |
| Deployment Strategy    | Blue-green with automated health checks, rollback, and 24 h drain          |
| Observability          | Prometheus + Grafana on EC2 + CloudWatch alarms + CloudWatch dashboard     |
| Cost Engineering       | 30-min ephemeral dev environments, Spot pricing, free-tier sizing          |
| Security Hardening     | Non-root containers, Trivy scanning, least-privilege IAM, REJECT flow logs |

---

## Branch → Environment Mapping

```
dev  ──push──▶  deploy.yml  ──▶  dev environment    auto-destroys in 30 minutes
main ──push──▶  deploy.yml  ──▶  prod environment   blue-green, manual destroy only
*    ──PR   ──▶  ci.yml      ──▶  lint + test + scan  no infrastructure touched
```

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│  GitHub Actions                                                          │
│                                                                          │
│  ci.yml      ▶  lint ▶ pytest ▶ Trivy container scan ▶ tf validate     │
│  deploy.yml  ▶  OIDC auth ▶ docker buildx ▶ ECR push ▶ tf apply        │
│  cleanup.yml ▶  tf destroy ▶ tag-based fallback ▶ S3 state wipe        │
└───────────────────────────┬──────────────────────────────────────────────┘
                            │  OIDC  (GitHub JWT ──▶ AWS STS AssumeRole)
                            │  No credentials stored anywhere
                            ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  AWS Account                                                             │
│                                                                          │
│  ECR (per-environment repos)          S3  nexusdeploy-terraform-state    │
│  ├── nexusdeploy-api-dev              ├── dev/terraform.tfstate          │
│  ├── nexusdeploy-api-prod             └── prod/terraform.tfstate         │
│  ├── nexusdeploy-worker-dev                                              │
│  └── nexusdeploy-worker-prod          SSM Parameter Store                │
│                               ┌───── /nexusdeploy/{env}/                 │
│  Secrets Manager              │      db/master_username  (SecureString)  │
│  {env}/app-secrets ◀──────────┘      db/master_password  (SecureString)  │
│  (injected by ECS at launch)         db/app_username     (SecureString)  │
│                                      db/app_password     (SecureString)  │
│                                      app/secret_key      (SecureString)  │
│                                      app/jwt_secret_key  (SecureString)  │
│                                      monitoring/grafana_password         │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  VPC  10.0.0.0/16 (dev)  │  10.1.0.0/16 (prod)                     │  │
│  │                                                                    │  │
│  │  ── Tier 1: Public Subnets ───────────────────────────────────     │  │
│  │  ┌──────────────────────────────────────────────────────────┐      │  │
│  │  │  Monitoring EC2  t3.micro  +  Elastic IP                 │      │  │
│  │  │  :9090 Prometheus  :3000 Grafana  :9100 Node Exporter    │      │  │
│  │  └──────────────────────────────────────────────────────────┘      │  │
│  │  [ ALB also placed here when enabled — see §Commented Features ]   │  │
│  │                                                                    │  │
│  │  ── Tier 2: Private App Subnets ──────────────────────────────     │  │
│  │  ┌──────────────────┐  ┌──────────────────┐  ┌────────────────┐    │  │
│  │  │  ECS: API        │  │  ECS: Worker     │  │  ECS: Beat     │    │  │
│  │  │  Flask/Gunicorn  │  │  Celery          │  │  Celery Beat   │    │  │
│  │  │  FARGATE_SPOT    │  │  FARGATE_SPOT    │  │  Singleton     │    │  │
│  │  └──────────────────┘  └──────────────────┘  └────────────────┘    │  │
│  │  prod runs two sets of the above (blue slot + green slot)          │  │
│  │                                                                    │  │
│  │  ── Tier 3: Private DB Subnets ────────────────────────────────    │  │
│  │  ┌──────────────────────────────────────────────────────────┐      │  │
│  │  │  RDS PostgreSQL  db.t3.micro  (multi-AZ subnet group)    │      │  │
│  │  └──────────────────────────────────────────────────────────┘      │  │
│  │                                                                    │  │
│  │  ── Tier 4: Private Cache Subnets ─────────────────────────────    │  │
│  │  ┌──────────────────────────────────────────────────────────┐      │  │
│  │  │  ElastiCache Redis  cache.t3.micro                       │      │  │
│  │  └──────────────────────────────────────────────────────────┘      │  │
│  └────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Terraform Module Structure

Modules are pure infrastructure blueprints — they have no idea which environment calls them. Environments pass different variable values; the modules stay reusable.

```
terraform/
├── modules/
│   ├── vpc/              VPC · 4-tier subnets · IGW · NAT · route tables · VPC flow logs
│   ├── ecs/              Cluster · task defs (API/worker/beat) · services · auto-scaling · circuit breaker
│   ├── rds/              PostgreSQL instance · subnet group · parameter group · slow-query logging
│   ├── elasticache/      Redis cluster · subnet group
│   ├── ecr/              Two repositories (api + worker) · lifecycle policy (keep last 3 images)
│   ├── iam/              OIDC provider · deploy role · ECS execution role · ECS task role · flow log role
│   ├── security-groups/  Per-service least-privilege rules
│   └── monitoring/       EC2 t3.micro · Prometheus · Grafana · Node Exporter · CW alarms · CW dashboard
│       └── templates/
│           └── monitoring-userdata.sh.tpl   full stack installed via EC2 user data at boot
└── environments/
    ├── dev/              30-min TTL · FARGATE_SPOT · NAT disabled · 3-day log retention
    └── prod/             Blue-green slots · manual destroy only · 7-day log retention
```

---

## Secrets — End-to-End Chain

No secret is ever written to a file, an environment variable on a developer's machine, or Terraform state in plaintext.

```
bootstrap.sh  (one-time, interactive CLI — run locally)
    │
    │  operator types values at prompt, never into a file
    ▼
SSM Parameter Store  (KMS-encrypted SecureString per parameter)
    /nexusdeploy/{env}/db/master_username
    /nexusdeploy/{env}/db/master_password      ← RDS superuser, Terraform only
    /nexusdeploy/{env}/db/app_username
    /nexusdeploy/{env}/db/app_password         ← limited app user, Flask only
    /nexusdeploy/{env}/app/secret_key
    /nexusdeploy/{env}/app/jwt_secret_key
    /nexusdeploy/{env}/monitoring/grafana_password
    │
    │  Terraform reads via  data "aws_ssm_parameter"
    │  values are never written to .tf files or tfvars
    ▼
Secrets Manager  ({env}/app-secrets)
    Terraform assembles one JSON secret from the SSM values above
    │
    │  ECS injects at task launch via  secrets: [ valueFrom: ARN ]
    ▼
Container environment variables  (DATABASE_URL, SECRET_KEY, JWT_SECRET_KEY …)
    │
    │  os.environ.get()  — application has zero knowledge of AWS
    ▼
Application runtime
```

**Two-user database pattern** — RDS master user (superuser, used only by Terraform and `init_db.py` at first boot) and a separate app user (SELECT / INSERT / UPDATE / DELETE only). The app never connects as superuser.

---

## CI/CD Pipeline

```
Every pull request
    └── ci.yml
        ├── flake8 + black                   lint
        ├── pytest                           56 tests, PostgreSQL + Redis
        │                                    run as GitHub Actions service containers
        ├── Trivy                            container vulnerability scan
        └── terraform validate               all environments, -backend=false

Push to dev branch
    └── deploy.yml
        ├── OIDC authentication              GitHub JWT → temp AWS credentials
        ├── docker buildx                    linux/amd64, GitHub Actions layer cache
        ├── ECR push                         image tagged with git SHA + latest
        ├── terraform init                   -backend-config flags, no hardcoded bucket
        ├── terraform apply                  deploys dev environment
        ├── post Grafana + Prometheus URLs   to GitHub Actions job summary
        └── schedule cleanup.yml            dispatched with 30-minute delay

Push to main branch
    └── deploy.yml
        ├── OIDC authentication
        ├── docker buildx + ECR push
        ├── read SSM active_slot            determines blue or green
        ├── terraform apply                 targets inactive slot only
        ├── health check loop               polls ECS runningCount every 30 s (5 min max)
        ├── on pass → update SSM active_slot + schedule old slot drain in 24 h
        └── on fail → scale failed slot to 0, old slot unchanged (instant rollback)
```

### OIDC — How the pipeline authenticates with no stored keys

```
1.  GitHub Actions runner requests a short-lived JWT
    from token.actions.githubusercontent.com

2.  JWT payload contains: repository, branch, workflow name, run ID

3.  deploy.yml calls  configure-aws-credentials  action
    which calls  aws sts AssumeRoleWithWebIdentity

4.  AWS validates the JWT signature against GitHub's published public keys
    and checks the role's trust policy:
        StringEquals  token.actions…:aud  sts.amazonaws.com
        StringLike    token.actions…:sub  repo:org/nexusdeploy:ref:refs/heads/dev

5.  AWS returns temporary credentials valid for 1 hour

6.  Credentials are used for ECR push and Terraform apply
    They expire automatically when the job ends
    Nothing is ever stored in GitHub Secrets except the role ARN
```

---

## Blue-Green Deployment (prod)

```
State before deploy:
    blue  desired=1  running=1  ← ACTIVE (serving traffic)
    green desired=0  running=0  ← IDLE

Deploy triggered on push to main:
    blue  desired=1  running=1  ← still active, traffic unaffected
    green desired=1  running=1  ← new image deploying to inactive slot

Health check loop (30 s interval, 5 min timeout):
    polls  aws ecs describe-services  for green runningCount == desiredCount

If health check PASSES:
    SSM  /nexusdeploy/prod/deployment/active_slot  ←  "green"
    prev images stored in SSM for next deploy's rollback reference
    cleanup.yml dispatched with 1440-minute (24 h) delay to drain blue

If health check FAILS or terraform apply fails:
    green scaled to desired=0 immediately
    SSM active_slot unchanged  →  blue remains active
    next deploy will target green again
    zero user impact

After 24 h drain:
    blue  desired=0  running=0  ← drained, ready for next deploy cycle
    green desired=1  running=1  ← active
```

Active slot is tracked in SSM at `/nexusdeploy/prod/deployment/active_slot`. The slot value is read at the start of every `deploy.yml` run and written only on a confirmed healthy deployment.

---

## Auto-Cleanup (dev — 30-minute TTL)

Dev environments are disposable by design. Every deploy automatically schedules its own destruction.

```
deploy.yml  dispatches  cleanup.yml  with  delay_minutes=30

cleanup.yml  Step 1 — terraform destroy  (clean path, preferred)

cleanup.yml  Step 2 — if terraform destroy fails for any reason,
             cleanup.sh  runs a tag-based fallback that deletes every
             resource tagged  Project=nexusdeploy  Environment=dev
             in strict dependency order:

  1.  ECS services        scale to 0 → deregister
  2.  ECR images          delete all untagged + old images
  3.  RDS instance        skip final snapshot
  4.  ElastiCache cluster
  5.  Secrets Manager     force-delete (no recovery window)
  6.  Security groups
  7.  NAT Gateway         release EIP
  8.  Internet Gateway    detach + delete
  9.  Subnets
  10. Route tables
  11. VPC
  12. CloudWatch log groups
  13. IAM roles + policies
  14. Verify             aws resourcegroupstaggingapi  confirms 0 tagged resources remain

cleanup.yml  Step 3 — delete S3 state file
             aws s3 rm s3://nexusdeploy-terraform-state/dev/terraform.tfstate
             prevents orphaned state from confusing future deployments
```

A nightly GitHub Actions cron also runs cleanup against any forgotten dev environments.

---

## Monitoring Stack

Both approaches run simultaneously and are available as datasources in the same Grafana dashboard.

### Prometheus + Grafana on EC2 t3.micro (free tier)

The entire monitoring stack is installed at EC2 boot time via `monitoring-userdata.sh.tpl` — no manual configuration.

| Component           | Port | Role                                                  |
| ------------------- | ---- | ----------------------------------------------------- |
| Prometheus          | 9090 | Scrapes Flask `/metrics` endpoint on ECS tasks        |
| Grafana             | 3000 | Visualises Prometheus + CloudWatch in one dashboard   |
| Node Exporter       | 9100 | System metrics for the monitoring EC2 itself          |
| CloudWatch Exporter | 9106 | Bridges CloudWatch ECS metrics into Prometheus format |

**ECS service discovery** — a shell script (`ecs-sd.sh`) runs every 60 seconds via cron. It calls `aws ecs list-tasks` + `describe-tasks` to find the private IPs of running API tasks and writes a Prometheus `file_sd` targets JSON. Prometheus reads this file and dynamically updates its scrape targets without a restart.

**Grafana auto-provisioning** — datasources and the dashboard JSON are written to `/etc/grafana/provisioning/` during userdata. Grafana picks them up on first start. No manual dashboard import needed.

Pre-built dashboard panels: HTTP request rate · p50/p95/p99 latency · 5xx error rate · ECS running task count · RDS CPU + connections (CloudWatch) · Redis memory (CloudWatch).

### CloudWatch (AWS-native, always on)

| What          | Detail                                                                              |
| ------------- | ----------------------------------------------------------------------------------- |
| Log groups    | `/ecs/nexusdeploy/{env}/api` · `/worker` · `/beat` · VPC flow logs                  |
| Log retention | 3 days (dev) · 7 days (prod)                                                        |
| Dashboard     | Provisioned by Terraform — ECS CPU, RDS CPU, Redis memory, error log Insights query |
| Alarms        | ECS API CPU > 80% · RDS CPU > 75% · Redis memory > 80%                              |
| VPC flow logs | REJECT traffic only — routed to CloudWatch for security auditing                    |

---

## Cost Engineering

Every sizing and configuration decision is deliberate.

| Resource           | Configuration                   | Why                                               | Cost                     |
| ------------------ | ------------------------------- | ------------------------------------------------- | ------------------------ |
| ECS Fargate (dev)  | FARGATE_SPOT, 256 CPU / 512 MB  | Spot = 70% cheaper, dev can tolerate interruption | ~$0.02 per 30-min run    |
| ECS Fargate (prod) | FARGATE on-demand, same size    | Spot not acceptable for prod                      | ~$0.05/hr while running  |
| RDS                | db.t3.micro                     | Free tier                                         | Free (750 hrs/month)     |
| ElastiCache        | cache.t3.micro                  | Free tier                                         | Free (750 hrs/month)     |
| Monitoring EC2     | t3.micro                        | Free tier                                         | Free (750 hrs/month)     |
| NAT Gateway        | Disabled in dev, single in prod | Per-AZ NAT = ~$1/day each                         | $0 dev · ~$0.045/hr prod |
| ECR lifecycle      | Keep last 3 images              | Prevents unbounded storage growth                 | <$0.01/month             |
| Log retention      | 3 d dev · 7 d prod              | CloudWatch storage is $0.03/GB/month              | Negligible               |
| **Total dev run**  |                                 |                                                   | **~$0.02**               |

---

## Commented-Out Features — Production-Ready, Cost-Disabled

These features are **fully implemented** in the codebase. They are commented out only to avoid cost during demo use. Each can be enabled with a small, targeted change.

---

### Application Load Balancer

**Files:** `terraform/modules/ecs/main.tf` · `terraform/modules/security-groups/main.tf`

Complete ALB stack written and commented:

- `aws_lb` — internet-facing, deletion protection enabled in prod, access logs to S3
- `aws_lb_target_group` — IP mode (required for Fargate), `/health` check, 2 healthy / 3 unhealthy thresholds
- `aws_lb_listener` HTTP :80 — uses a `dynamic` block to redirect to HTTPS in prod and forward directly in non-prod
- `aws_lb_listener` HTTPS :443 — TLS 1.3 security policy (`ELBSecurityPolicy-TLS13-1-2-2021-06`), ACM certificate
- `aws_security_group.alb` — :80/:443 from `0.0.0.0/0`, egress scoped to app security group only
- ECS service `load_balancer {}` block — wires API containers to the target group on port 5000
- API security group ingress — comment shows how to switch from VPC CIDR to `security_groups = [alb_sg_id]`

**To enable:** uncomment the ALB blocks in both files, provide `var.acm_certificate_arn` and `var.alb_logs_bucket` in tfvars.
**Cost:** ~$16/month for the ALB.

---

### DynamoDB State Locking

**Files:** `scripts/bootstrap.sh` · `terraform/environments/dev/main.tf` · `terraform/environments/prod/main.tf` · `.github/workflows/deploy.yml`

Terraform state locking prevents two concurrent `terraform apply` runs from corrupting the state file. Disabled because this is a single-developer project with sequential deployments — concurrent state writes cannot occur.

Enabled in three steps:

1. Uncomment the `aws dynamodb create-table` block in `bootstrap.sh` and re-run `make bootstrap`
2. Add `dynamodb_table = "nexusdeploy-terraform-locks"` to the `backend "s3"` block in each environment's `main.tf`
3. Uncomment `TF_LOCK_TABLE: nexusdeploy-terraform-locks` in `deploy.yml`

**Cost when enabled:** $0 — DynamoDB PAY_PER_REQUEST, lock volume at this scale is negligible.

---

### S3 State Bucket — Explicit Encryption + Lifecycle Policy

**File:** `scripts/bootstrap.sh`

Two hardening blocks are commented out with `log_warn` annotations:

- **Explicit AES256 SSE** via `aws s3api put-bucket-encryption` — S3 default encryption now covers this automatically, but an explicit configuration demonstrates intentional security posture.
- **Lifecycle policy** via `aws s3api put-bucket-lifecycle-configuration` — transitions non-current state versions to `STANDARD_IA` after 30 days and expires them after 90 days. Keeps the state bucket lean as deployment history accumulates.

---

### NAT Gateway (dev)

**File:** `terraform/environments/dev/main.tf` — `enable_nat_gateway = false`

Private ECS tasks in dev reach AWS APIs (ECR, Secrets Manager, SSM) through VPC endpoints. Outbound internet access from private subnets is not available without a NAT Gateway. Set `enable_nat_gateway = true` to enable it.

**Cost when enabled:** ~$1/day ($0.045/hr + data transfer charges).

---

### NAT Gateway per Availability Zone (prod high availability)

**File:** `terraform/modules/vpc/main.tf`

A comment in the NAT Gateway resource block documents the trade-off: a single NAT Gateway is a single point of failure. If the AZ hosting the NAT GW goes down, all private subnet outbound traffic fails. True HA requires one NAT GW per AZ.

To enable: change `count = var.enable_nat_gateway ? 1 : 0` to `count = var.enable_nat_gateway ? length(var.availability_zones) : 0` on both `aws_eip.nat` and `aws_nat_gateway.main`, and update the route table associations to use the AZ-local gateway.

**Cost per additional AZ:** ~$1/day.

---

### ECS Container Insights (dev)

**File:** `terraform/modules/ecs/main.tf` — `containerInsights` setting on the cluster

Container Insights is already enabled in prod. Disabled in dev via:

```hcl
value = var.environment == "prod" ? "enabled" : "disabled"
```

Container Insights publishes per-container CPU, memory, network, and storage metrics to CloudWatch at higher resolution than the default ECS service-level metrics. Change the condition to enable it in dev.

**Cost when enabled:** ~$0.35 per container per month.

---

### CodeDeploy Deployment Controller

**File:** `terraform/modules/ecs/main.tf` — `deployment_controller` block on the API ECS service

```hcl
deployment_controller {
  type = "ECS"
  # For AWS-managed blue/green: type = "CODE_DEPLOY"
}
```

The current blue-green implementation is Terraform-native: two ECS service sets with slot tracking via SSM. `type = "CODE_DEPLOY"` is the AWS-managed alternative — it integrates with ALB listener rule weights to shift traffic gradually (e.g. 10% → 50% → 100%), provides a deployment timeline in the CodeDeploy console, and supports approval gates per traffic shift step. Requires ALB to be enabled first.

---

## Repository Structure

```
nexusdeploy/
│
├── app/                          the workload — exists to give the infra something real to operate
│   ├── src/
│   ├── tests/
│   ├── Dockerfile                Gunicorn, non-root user, --chdir src, 2 workers (right-sized for 256CPU/512MB)
│   └── Dockerfile.worker         Celery, non-root user, concurrency=2
│
├── terraform/
│   ├── modules/                  reusable blueprints — never run directly
│   │   ├── vpc/
│   │   ├── ecs/
│   │   ├── rds/
│   │   ├── elasticache/
│   │   ├── ecr/
│   │   ├── iam/
│   │   ├── security-groups/
│   │   └── monitoring/
│   │       └── templates/
│   │           └── monitoring-userdata.sh.tpl
│   └── environments/
│       ├── dev/                  calls modules with dev values, 30-min TTL tag
│       └── prod/                 calls modules with prod values, blue + green ECS sets
│
├── .github/workflows/
│   ├── ci.yml                    lint · test · Trivy · terraform validate
│   ├── deploy.yml                OIDC · build · push · apply · blue-green logic
│   └── cleanup.yml               terraform destroy · tag fallback · S3 wipe
│
├── scripts/
│   ├── bootstrap.sh              one-time: S3 · OIDC provider · IAM role · SSM secrets
│   └── cleanup.sh                10-step tag-based fallback (dependency-ordered deletes)
│
├── Makefile                      operational shortcuts: up · test · tf-apply · shell · secrets · prod-active-slot
├── docker-compose.yml            local development only
└── docs/
    └── SETUP.md                  GitHub Secrets guide · OIDC explanation · cost breakdown
```

---

## Operational Runbook

```bash
# ── One-time bootstrap ─────────────────────────────────────────────────────
export GITHUB_ORG=your-github-username
make bootstrap
# Creates: S3 state bucket · GitHub OIDC provider · IAM deploy role
# Prompts: all secrets → stored in SSM Parameter Store (never in files)

# Add one GitHub repository secret:
# Settings → Secrets → Actions → New repository secret
# Name:  AWS_DEPLOY_ROLE_ARN
# Value: (ARN printed by bootstrap)

# Update tfvars in both environments:
# terraform/environments/dev/terraform.tfvars  → github_org = "your-username"
# terraform/environments/prod/terraform.tfvars → github_org = "your-username"

# ── Deploy ──────────────────────────────────────────────────────────────────
git push origin dev     # deploys dev, auto-destroys in 30 minutes
git push origin main    # blue-green deploy to prod

# ── Observe ────────────────────────────────────────────────────────────────
make status             ENV=dev    # ECS service running/desired counts
make logs               ENV=dev    # tail CloudWatch logs live
make prod-active-slot              # which slot is currently active (blue/green)
make monitoring-url     ENV=prod   # print Grafana URL

# ── Access containers (no SSH keys — SSM Session Manager) ─────────────────
make shell              ENV=dev    # ECS Exec into running API container

# ── Emergency ──────────────────────────────────────────────────────────────
make cleanup            ENV=dev    # run tag-based cleanup script manually
make cleanup-dry        ENV=dev    # dry run — shows what would be deleted
make prod-state-download           # download prod state locally for manual destroy
```
