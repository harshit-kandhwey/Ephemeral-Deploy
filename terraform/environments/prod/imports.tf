# ─────────────────────────────────────────────────────────────────────────────
# imports.tf — Adopt bootstrap-created resources into Terraform state
#
# The GitHub OIDC provider and deploy IAM role are owned by bootstrap.sh.
# Bootstrap is the source of truth for their permissions — Terraform imports
# them into state so it can reference them, but never modifies them.
#
# lifecycle { ignore_changes = all } in modules/iam/main.tf ensures Terraform
# will never overwrite what bootstrap created, even if the config differs.
#
# How it works (Terraform 1.5+):
#   First apply  → imports existing resource into state, no changes made
#   Subsequent   → resource already in state, import block silently ignored
#
# NOTE: import block `id` values must be literal strings — expressions are
# not supported. Account ID 415838720130 is hardcoded intentionally.
# ─────────────────────────────────────────────────────────────────────────────

# GitHub OIDC provider: create_oidc_provider = false in prod, so the resource
# has count = 0 and cannot be imported here. The provider is created by dev env
# (create_oidc_provider = true) and shared — reference it via var.oidc_provider_arn
# if the IAM module trust policy needs it.

# GitHub Actions deploy IAM role — owned by bootstrap.sh, shared
import {
  to = module.iam.aws_iam_role.github_actions_deploy
  id = "nexusdeploy-github-actions-deploy"
}

# Inline policies — split into two to stay under 10240 char limit per policy
# Same policies as dev; these are shared bootstrap-owned resources
import {
  to = module.iam.aws_iam_role_policy.github_actions_deploy
  id = "nexusdeploy-github-actions-deploy:nexusdeploy-github-actions-deploy-1"
}

import {
  to = module.iam.aws_iam_role_policy.github_actions_deploy_2
  id = "nexusdeploy-github-actions-deploy:nexusdeploy-github-actions-deploy-2"
}

# ECR repositories are managed by the ecr-provision job — NO import blocks here.
# Import blocks hard-fail when the remote object doesn't exist, and ecr-provision's
# targeted apply only runs when the repos are missing — exactly when the import
# would fail. The repos-exist-but-state-wiped case is handled by the tolerant
# adopt() step (terraform import || true) in deploy.yml instead.
