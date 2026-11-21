output "alb_dns_name" {
  description = "Application Load Balancer DNS Name"
  value       = module.alb.alb_dns_name
}

output "app_url" {
  description = "Direct HTTP access URL to the AWS primary application"
  value       = "http://${module.alb.alb_dns_name}"
}

output "health_endpoint" {
  description = "Health check probe endpoint for global DNS failover"
  value       = "http://${module.alb.alb_dns_name}/api/health?probe=readiness"
}

output "ecr_repository_url" {
  description = "ECR Repository URL for container image pushes"
  value       = module.ecr.repository_url
}

output "rds_endpoint" {
  description = "PostgreSQL RDS connection endpoint"
  value       = module.rds.rds_endpoint
}

output "ecs_cluster_name" {
  description = "ECS Cluster Name"
  value       = module.ecs.cluster_name
}

output "ecs_service_name" {
  description = "ECS Service Name"
  value       = module.ecs.service_name
}

output "cloudwatch_dashboard_name" {
  description = "SRE CloudWatch Dashboard Name"
  value       = module.monitoring.dashboard_name
}

output "cost_budget_name" {
  description = "AWS FinOps Budget Name"
  value       = module.finops.budget_name
}

output "github_actions_role_arn" {
  description = "OIDC IAM Role ARN for GitHub Actions deployments"
  value       = module.iam.github_actions_role_arn
}
