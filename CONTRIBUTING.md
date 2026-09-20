# Contributing to Ephemeral Deploy

Thank you for your interest in contributing. This document covers how to set up the project locally, the branch and PR workflow, and the standards expected for contributions.

## Project Overview

Ephemeral Deploy is a production-grade AWS DevOps pipeline that deploys a Flask project management REST API. That application — the workload — lives in its own repository, [Nexusdeploy-App](https://github.com/harshit-kandhwey/Nexusdeploy-App), and owns all application code; this repo is the AWS ECS infrastructure (Terraform, blue-green deployment, CI/CD, monitoring) around it. Application changes go to Nexusdeploy-App, not here. See [README.md](README.md) and [CLAUDE.md](CLAUDE.md) for full architecture details.

## Getting Started

### Prerequisites

- Terraform 1.5+ (for infrastructure changes)
- AWS CLI configured (for deploy/ops commands)
- Docker and Python 3.11+ — only for application work, which happens in Nexusdeploy-App

### Running the application locally

The application, its compose file and its tests belong to Nexusdeploy-App — run these from a checkout of that repo, not this one:

```bash
# Start the full stack (postgres + redis + api + worker + beat + redis-commander)
docker-compose up -d

# API: http://localhost:5000
# Swagger UI: http://localhost:5000/apidocs
# Redis Commander: http://localhost:8081
```

### Running the application's tests

From a Nexusdeploy-App checkout:

```bash
pytest tests/ -v --cov=src --cov-report=term-missing --cov-fail-under=85
```

Tests use in-memory SQLite and Redis DB 15 — no external services needed.

### Linting the application

From a Nexusdeploy-App checkout:

```bash
flake8 src/ --max-line-length=120 && black --check src/ && bandit -r src/ -ll
black .   # auto-format
isort .   # sort imports
```

Line length is 120 (set in that repo's `pyproject.toml`).

### Checks for this repo

`ci.yml` runs these on pushes to `main`/`dev`/`staging`/`feature/**` and on PRs to `main`/`dev`/`staging`. Run the local equivalents before pushing:

| CI job | Runs | Local equivalent |
| --- | --- | --- |
| `workflow-lint` (always) | Fails if a `${{ vars.* / secrets.* / needs.*.outputs.* }}` expression is interpolated directly inside an `echo "..."` string | see the pattern in `ci.yml` |
| `secrets-scan` (always, **blocking**) | gitleaks over the full history | `gitleaks detect --source . --redact --verbose` |
| `terraform-lint` (only if `terraform/` or `.github/` changed) | `terraform fmt -recursive` (pushes a `[skip ci]` formatting commit if it changes anything), TFLint and Checkov (both non-blocking), then `terraform init -backend=false`, `terraform validate` and an offline `terraform plan -refresh=false` for each of `dev`, `staging`, `prod` | `terraform fmt -check -recursive terraform/`; then in each `terraform/environments/<env>`: `terraform init -backend=false && terraform validate` |
| `ci-summary` | The required check: gates on the jobs above and, on success, dispatches `deploy.yml` | — |

Because the CI plan is offline (`-refresh=false`), it does not show drift against real AWS — review a real `terraform plan` for infrastructure changes.

## Branch and PR Workflow

| Branch       | Purpose                                                                                  |
| ------------ | ---------------------------------------------------------------------------------------- |
| `feature/**` | Your work. Opens a PR → CI runs workflow-lint, secret scan and (if infra changed) terraform-lint. No AWS touched. |
| `dev`        | Integration. Merging here auto-deploys to the dev environment (auto-destroys in 30 min). |
| `main`       | Production. Merging here triggers a blue-green prod deploy.                              |

1. Fork the repo and create a branch from `dev`: `git checkout -b feature/my-change`
2. Make your changes (application changes belong in Nexusdeploy-App)
3. Run the checks in [Checks for this repo](#checks-for-this-repo) locally before pushing
4. Open a PR targeting `dev`
5. All CI checks must pass before merging

## Contribution Standards

### Code

- Follow existing patterns. Look at adjacent files before writing new code.
- No commented-out code, no `TODO` left in production paths.
- Application code — endpoints, tests, dependencies, Python formatting — lives in Nexusdeploy-App; changes to it go there.

### Terraform

- All new resources go in modules under `terraform/modules/`. Environments only instantiate modules.
- Run `terraform fmt -recursive terraform/` before committing. CI runs it too and pushes a `[skip ci]` formatting commit if anything changed.
- State lives in S3 with DynamoDB locking (table `nexusdeploy-terraform-locks`, created by `scripts/bootstrap.sh`), so a concurrent `plan`/`apply` fails on the lock instead of corrupting state. When running Terraform locally, pass the same `-backend-config` values the workflows use (see `deploy.yml`).

### Commit Messages

Use the conventional commits style:

```
<type>: <short summary>

<optional body explaining why, not what>
```

Types: `feat`, `fix`, `perf`, `refactor`, `test`, `chore`, `docs`, `ci`

### Security

If you discover a security vulnerability, **do not open a public issue**. See [SECURITY.md](SECURITY.md) for responsible disclosure instructions.

## What We Welcome

- Bug fixes with regression tests
- Performance improvements (especially to database queries or CI pipeline steps)
- Documentation improvements
- Infrastructure hardening (IAM least-privilege, security group tightening, etc.)

## What to Avoid

- Changes that break CI (terraform validate, workflow lint, secret scan) without a clear reason
- Adding new AWS resource types without updating `bootstrap.sh` and IAM permissions
- Adding application code or dependencies here — they belong in Nexusdeploy-App
- Disabling or bypassing CI checks
