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
