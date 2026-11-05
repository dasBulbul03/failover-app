output "app_runner_service_url" {
  description = "App Runner service URL (secondary endpoint)"
  value       = "https://${aws_apprunner_service.app.service_url}"
}

output "ecr_repo_url" {
  description = "ECR repository URL for pushing Docker images"
  value       = aws_ecr_repository.app.repository_url
}

output "rds_connection_string" {
  description = "PostgreSQL connection string"
  value       = "postgresql://pgadmin:PASSWORD@${aws_db_instance.postgres.endpoint}/failoverdb?sslmode=require"
  sensitive   = true
}
