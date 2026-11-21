module "prod_failover_app" {
  source = "../../"

  environment              = "prod"
  aws_region               = var.aws_region
  app_name                 = var.app_name
  db_password              = var.db_password
  desired_count            = 1 # Warm Standby
  enable_nat_gateway       = false
  log_retention_days       = 14
  monthly_budget_limit_usd = 60
  tags = {
    Environment = "prod"
    ManagedBy   = "Terraform"
    Tier        = "DisasterRecovery-Secondary"
  }
}

variable "aws_region" {
  default = "ap-southeast-2"
}

variable "app_name" {
  default = "failover-app"
}

variable "db_password" {
  sensitive = true
}

output "alb_dns_name" {
  value = module.prod_failover_app.alb_dns_name
}

output "app_url" {
  value = module.prod_failover_app.app_url
}

output "health_endpoint" {
  value = module.prod_failover_app.health_endpoint
}
