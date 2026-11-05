variable "aws_region" {
  description = "AWS region for secondary deployment"
  type        = string
  default     = "us-east-1"
}

variable "db_password" {
  description = "RDS PostgreSQL master password"
  type        = string
  sensitive   = true
}

variable "container_image_uri" {
  description = "ECR image URI (account.dkr.ecr.region.amazonaws.com/name:tag)"
  type        = string
}

variable "app_name" {
  description = "Application name used for all resource naming"
  type        = string
  default     = "failover-app"
}
