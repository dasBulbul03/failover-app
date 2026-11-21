output "execution_role_arn" {
  description = "ARN of the ECS Execution Role"
  value       = aws_iam_role.ecs_execution.arn
}

output "task_role_arn" {
  description = "ARN of the ECS Task Role"
  value       = aws_iam_role.ecs_task.arn
}
