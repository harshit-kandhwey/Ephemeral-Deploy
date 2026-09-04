# Adopts bootstrap-created resources into Terraform state. See
# docs/design-decisions.md#bootstrap-owns-the-deploy-role-identity. Terraform
# import block `id` values must be literal strings, not expressions — the
# account ID below is hardcoded for that reason, not by oversight.

import {
  to = module.iam.aws_iam_openid_connect_provider.github[0]
  id = "arn:aws:iam::415838720130:oidc-provider/token.actions.githubusercontent.com"
}

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
