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

# GitHub OIDC provider — owned by bootstrap.sh, never modified by Terraform
import {
  to = module.iam.aws_iam_openid_connect_provider.github[0]
  id = "arn:aws:iam::415838720130:oidc-provider/token.actions.githubusercontent.com"
}

# GitHub Actions deploy IAM role — owned by bootstrap.sh
import {
  to = module.iam.aws_iam_role.github_actions_deploy
  id = "nexusdeploy-github-actions-deploy"
}

# Inline policy — policy name matches bootstrap.sh: ${PROJECT}-github-actions-full-deploy
import {
  to = module.iam.aws_iam_role_policy.github_actions_deploy
  id = "nexusdeploy-github-actions-deploy:nexusdeploy-github-actions-full-deploy"
}

# ECR repositories and lifecycle policies are managed by the ecr-provision job.
# Import blocks are NOT used for ECR because:
#   - If repos exist → ecr-provision skips terraform apply, main apply creates them fresh
#   - If repos missing → ecr-provision creates them via terraform apply -target=module.ecr
# Import blocks for ECR would fail when repos don't exist (e.g. after fallback cleanup).

# ECR repositories — always exist after first ecr-provision job run.
# ecr-provision job guarantees these exist in AWS before deploy-dev runs.
# Import blocks are idempotent — silently no-op if already in state.
import {
  to = module.ecr.aws_ecr_repository.api
  id = "nexusdeploy-api-dev"
}

import {
  to = module.ecr.aws_ecr_repository.worker
  id = "nexusdeploy-worker-dev"
}
