output "rds_endpoint" {
  description = "The connection endpoint in address:port format"
  value       = aws_db_instance.postgres.endpoint
}

output "rds_address" {
  description = "The hostname of the RDS instance"
  value       = aws_db_instance.postgres.address
}

output "rds_port" {
  description = "The database port"
  value       = aws_db_instance.postgres.port
}

output "rds_db_name" {
  description = "The database name"
  value       = aws_db_instance.postgres.db_name
}

output "rds_arn" {
  description = "The ARN of the RDS instance"
  value       = aws_db_instance.postgres.arn
}
