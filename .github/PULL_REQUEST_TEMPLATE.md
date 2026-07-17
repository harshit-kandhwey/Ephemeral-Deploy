## Summary

<!-- What does this PR do? 1-3 bullet points. -->

-
-

## Type of Change

- [ ] Bug fix
- [ ] New feature
- [ ] Performance improvement
- [ ] Refactor (no functional change)
- [ ] Infrastructure / Terraform
- [ ] CI/CD pipeline
- [ ] Documentation

## Related Issues

<!-- Closes #123 -->

## Test Plan

<!-- How did you verify this works? Check all that apply. -->

- [ ] Unit / integration tests added or updated (`cd app && pytest tests/ -v --cov=src --cov-report=term-missing` passes)
- [ ] Manually tested against local stack (`docker-compose up -d`)
- [ ] Tested against dev environment (pushed to `dev` branch)
- [ ] No test needed — reason: \_\_\_

## Checklist

- [ ] Lint passes locally (`cd app && flake8 src/ --max-line-length=120 && black --check src/ && bandit -r src/ -ll -x src/tests/`)
- [ ] No hardcoded secrets, credentials, or environment-specific values in code
- [ ] Terraform changes: `terraform fmt` applied, `terraform plan` reviewed
- [ ] New API endpoints have Swagger docstrings
- [ ] CLAUDE.md updated if architecture or commands changed

## Notes for Reviewer

<!-- Anything the reviewer should pay particular attention to, tricky edge cases, or follow-up work. -->
