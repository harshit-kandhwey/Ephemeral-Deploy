# Contributing to Ephemeral Deploy

Thank you for your interest in contributing. This document covers how to set up the project locally, the branch and PR workflow, and the standards expected for contributions.

## Project Overview

Ephemeral Deploy is a production-grade AWS DevOps pipeline built around a Flask project management REST API. The application in `app/` is the workload — the infrastructure and CI/CD pipeline around it is the primary subject. See [README.md](README.md) and [CLAUDE.md](CLAUDE.md) for full architecture details.

## Getting Started

### Prerequisites

- Docker and Docker Compose
- Python 3.11+ (for local test runs without Docker)
- Terraform 1.5+ (for infrastructure changes)
- AWS CLI configured (for deploy/ops commands)

### Local Development

```bash
# Start the full stack (postgres + redis + api + worker + beat + redis-commander)
make up

# API: http://localhost:5000
# Swagger UI: http://localhost:5000/apidocs
# Redis Commander: http://localhost:8081
```

### Running Tests

```bash
make test

# Or with more control, from app/
cd app
pytest tests/ -v --cov=src --cov-report=term-missing
```

Tests use in-memory SQLite and Redis DB 15 — no external services needed.

### Linting

```bash
make lint          # flake8 + black --check + bandit
cd app && black .  # auto-format
cd app && isort .  # sort imports
```

Line length is 120 (set in `pyproject.toml`).

## Branch and PR Workflow

| Branch       | Purpose                                                                                  |
| ------------ | ---------------------------------------------------------------------------------------- |
| `feature/**` | Your work. Opens a PR → CI runs lint, test, scan. No AWS touched.                        |
| `dev`        | Integration. Merging here auto-deploys to the dev environment (auto-destroys in 45 min). |
| `main`       | Production. Merging here triggers a blue-green prod deploy.                              |

1. Fork the repo and create a branch from `dev`: `git checkout -b feature/my-change`
2. Make your changes with tests
3. Run `make lint` and `make test` locally before pushing
4. Open a PR targeting `dev`
5. All CI checks must pass before merging

## Contribution Standards

### Code

- Follow existing patterns. Look at adjacent files before writing new code.
- No commented-out code, no `TODO` left in production paths.
- Every new API endpoint needs a corresponding test in `app/tests/`.
- Line length 120. Black + isort formatting is enforced by CI (auto-commits on PRs).

### Terraform

- All new resources go in modules under `terraform/modules/`. Environments only instantiate modules.
- Run `terraform fmt` before committing. CI enforces this.
- State locking is disabled (single-developer workflow) — coordinate before running concurrent applies.

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
- New API endpoints with full test coverage

## What to Avoid

- Changes that break the existing test suite without a clear reason
- Adding new AWS resource types without updating `bootstrap.sh` and IAM permissions
- Introducing new Python dependencies without justification (keep the image lean)
- Disabling or bypassing CI checks
