variable "aws_region" {
  description = "AWS region for disaster recovery deployment"
  type        = string
  default     = "ap-southeast-2"
}

variable "environment" {
  description = "Deployment environment name (dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "app_name" {
  description = "Application name used across resource identifiers"
  type        = string
  default     = "failover-app"
}

variable "vpc_cidr" {
  description = "VPC CIDR address space"
  type        = string
  default     = "10.0.0.0/16"
}

variable "container_port" {
  description = "Internal port exposed by the application container"
  type        = number
  default     = 3000
}

variable "container_image_uri" {
  description = "ECR image URI to deploy. If blank, defaults to repository_url:latest"
  type        = string
  default     = ""
}

variable "ecs_cpu" {
  description = "ECS Task CPU allocation (256 = 0.25 vCPU)"
  type        = number
  default     = 256
}

variable "ecs_memory" {
  description = "ECS Task Memory allocation in MB"
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Desired number of ECS tasks (FinOps: 1 in warm standby, 0 in cold pilot-light)"
  type        = number
  default     = 1
}

variable "enable_nat_gateway" {
  description = "Provision NAT Gateway for strict private egress (FinOps: false saves ~$32/month in standby)"
  type        = bool
  default     = false
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = "failoverdb"
}

variable "db_username" {
  description = "PostgreSQL master username"
  type        = string
  default     = "pgadmin"
}

variable "db_password" {
  description = "PostgreSQL master password"
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class (db.t4g.micro for dev/pilot-light)"
  type        = string
  default     = "db.t4g.micro"
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 7
}

variable "monthly_budget_limit_usd" {
  description = "Monthly budget limit in USD for FinOps cost alerts"
  type        = number
  default     = 50
}

variable "alert_email_addresses" {
  description = "Email addresses to receive budget and health alerts"
  type        = list(string)
  default     = []
}

variable "alarm_email" {
  description = "Email address for CloudWatch alarm notifications via SNS. Leave empty to disable email subscription."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
