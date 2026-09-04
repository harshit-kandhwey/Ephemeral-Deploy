# Adopts bootstrap-created resources into Terraform state (same pattern as
# every environment). See
# docs/design-decisions.md#bootstrap-owns-the-deploy-role-identity

import {
  to = module.iam.aws_iam_role.github_actions_deploy
  id = "nexusdeploy-github-actions-deploy"
}

import {
  to = module.iam.aws_iam_role_policy.github_actions_deploy
  id = "nexusdeploy-github-actions-deploy:nexusdeploy-github-actions-deploy-1"
}

import {
  to = module.iam.aws_iam_role_policy.github_actions_deploy_2
  id = "nexusdeploy-github-actions-deploy:nexusdeploy-github-actions-deploy-2"
}

# ECR is deliberately NOT imported here: a missing repo would fail this
# import outright, whereas ecr-provision's own `terraform apply
# -target=module.ecr` creates it; deploy.yml's tolerant `adopt()` (import ||
# true) handles the case where the repo exists but state was wiped.
