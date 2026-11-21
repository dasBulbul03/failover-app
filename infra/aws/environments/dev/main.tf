module "dev_failover_app" {
  source = "../../"

  environment              = "dev"
  aws_region               = var.aws_region
  app_name                 = var.app_name
  db_password              = var.db_password
  desired_count            = 1
  enable_nat_gateway       = false # FinOps savings for dev
  log_retention_days       = 7
  monthly_budget_limit_usd = 25
  tags = {
    Environment = "dev"
    ManagedBy   = "Terraform"
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
  value = module.dev_failover_app.alb_dns_name
}

output "app_url" {
  value = module.dev_failover_app.app_url
}
