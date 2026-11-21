output "log_group_name" {
  description = "The name of the CloudWatch Log Group"
  value       = aws_cloudwatch_log_group.ecs.name
}

output "log_group_arn" {
  description = "The ARN of the CloudWatch Log Group"
  value       = aws_cloudwatch_log_group.ecs.arn
}

output "dashboard_name" {
  description = "The name of the CloudWatch Dashboard"
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}
