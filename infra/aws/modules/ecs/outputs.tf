output "cluster_id" {
  description = "The ID of the ECS Cluster"
  value       = aws_ecs_cluster.main.id
}

output "cluster_name" {
  description = "The Name of the ECS Cluster"
  value       = aws_ecs_cluster.main.name
}

output "service_name" {
  description = "The Name of the ECS Service"
  value       = aws_ecs_service.app.name
}

output "task_definition_arn" {
  description = "The ARN of the ECS Task Definition"
  value       = aws_ecs_task_definition.app.arn
}
