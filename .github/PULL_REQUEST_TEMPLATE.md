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

## Verification

<!-- This repo is the AWS ECS infrastructure only; application code lives in Nexusdeploy-App. Check all that apply. CI runs: workflow-lint and secrets-scan on every run, and terraform-lint when terraform/ or .github/ changed. -->

- [ ] `terraform fmt -check -recursive terraform/` is clean (CI auto-formats and pushes a `[skip ci]` commit otherwise)
- [ ] `terraform init -backend=false && terraform validate` passes for each environment touched (CI validates and plans offline for `dev`, `staging` and `prod`)
- [ ] Terraform changes: a real `terraform plan` was reviewed (CI's plan is offline, `-refresh=false`, so it cannot show drift)
- [ ] Workflow changes: no `${{ vars.* }}`, `${{ secrets.* }}` or `${{ needs.*.outputs.* }}` interpolated directly inside an `echo "..."` string (the Workflow Quoting Safety Check fails the run otherwise)
- [ ] No secrets or credentials committed (the gitleaks scan blocks the build)
- [ ] TFLint / Checkov findings reviewed (non-blocking — they warn, they do not fail the run)
- [ ] Tested against the dev environment (pushed to `dev`; this spends real AWS money against the $1/month cap)
- [ ] No test needed — reason: \_\_\_

## Checklist

- [ ] This PR contains no application code (that belongs in Nexusdeploy-App)
- [ ] No environment-specific values hardcoded in code
- [ ] `Readme.md` / `docs/design-decisions.md` updated if architecture, commands or a non-obvious decision changed
- [ ] Repo convention (not a CI check): no `[skip ci]` on a commit that is, or will become, this PR's head — GitHub then never runs the required `CI Summary` check and the PR stays blocked; use `[skip deploy]` to suppress only the deploy

## Notes for Reviewer

<!-- Anything the reviewer should pay particular attention to, tricky edge cases, or follow-up work. -->
