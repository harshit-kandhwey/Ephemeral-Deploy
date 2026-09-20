output "grafana_url" {
  description = "Grafana dashboard URL"
  value       = "http://${aws_eip.monitoring.public_ip}:3000"
}

output "prometheus_url" {
  description = "Prometheus UI URL"
  value       = "http://${aws_eip.monitoring.public_ip}:9090"
}

output "monitoring_instance_id" {
  description = "EC2 instance ID for the monitoring server"
  value       = aws_instance.monitoring.id
}

output "monitoring_public_ip" {
  description = "Elastic IP address of the monitoring server"
  value       = aws_eip.monitoring.public_ip
}

output "monitoring_private_ip" {
  description = "Private IP of the monitoring server — ECS tasks export OTLP traces here, VPC-internal only"
  value       = aws_instance.monitoring.private_ip
}

output "jaeger_access_command" {
  description = "Jaeger's UI is loopback-only (unauthenticated); run this, then open http://localhost:16686. Grafana's Jaeger datasource also works with no port-forward."
  value       = "aws ssm start-session --target ${aws_instance.monitoring.id} --region ${var.aws_region} --document-name AWS-StartPortForwardingSession --parameters portNumber=16686,localPortNumber=16686"
}
