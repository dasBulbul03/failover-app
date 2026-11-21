output "vpc_id" {
  description = "The ID of the VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "private_app_subnet_ids" {
  description = "List of private app subnet IDs"
  value       = aws_subnet.private_app[*].id
}

output "private_db_subnet_ids" {
  description = "List of private database subnet IDs"
  value       = aws_subnet.private_db[*].id
}

output "alb_security_group_id" {
  description = "Security Group ID of the ALB"
  value       = aws_security_group.alb.id
}

output "ecs_security_group_id" {
  description = "Security Group ID of the ECS tasks"
  value       = aws_security_group.ecs_tasks.id
}

output "rds_security_group_id" {
  description = "Security Group ID of the RDS PostgreSQL instance"
  value       = aws_security_group.rds.id
}
