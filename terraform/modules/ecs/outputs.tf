output "cluster_name" {
  description = "ECS cluster name — used by monitoring module for Prometheus service discovery"
  value       = aws_ecs_cluster.main.name
}

output "cluster_id" {
  description = "ECS cluster ARN"
  value       = aws_ecs_cluster.main.id
}

output "api_service_name" {
  description = "ECS API service name"
  value       = aws_ecs_service.api.name
}

output "worker_service_name" {
  description = "ECS worker service name"
  value       = aws_ecs_service.worker.name
}
