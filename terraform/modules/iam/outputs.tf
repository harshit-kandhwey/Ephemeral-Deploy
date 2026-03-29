output "ecs_execution_role_arn" {
  description = "IAM role ARN for ECS task execution (ECR pull + CloudWatch logs)"
  value       = aws_iam_role.ecs_execution.arn
}

output "ecs_task_role_arn" {
  description = "IAM role ARN for the running application (S3, Secrets Manager, etc.)"
  value       = aws_iam_role.ecs_task.arn
}

output "vpc_flow_log_role_arn" {
  description = "IAM role ARN for VPC Flow Logs to write to CloudWatch"
  value       = aws_iam_role.vpc_flow_log.arn
}

output "github_actions_deploy_role_arn" {
  description = "IAM role ARN assumed by GitHub Actions via OIDC"
  value       = aws_iam_role.github_actions_deploy.arn
}
