# ─────────────────────────────────────────────────────────────────────────────
# imports.tf — Adopt bootstrap-created resources into Terraform state
#
# Same pattern as prod/imports.tf. Bootstrap creates the OIDC provider and
# deploy role once; staging imports them for reference only.
#
# ECR repos for staging are created by ecr-provision in CI (same as dev/prod).
# Import blocks here ensure first `terraform apply` does not fail if repos
# already exist from a previous run.
# ─────────────────────────────────────────────────────────────────────────────

# GitHub Actions deploy IAM role — owned by bootstrap.sh, shared across all envs
import {
  to = module.iam.aws_iam_role.github_actions_deploy
  id = "nexusdeploy-github-actions-deploy"
}

# Inline policies — split into two to stay under 10240 char limit per policy
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
