variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "ap-southeast-2"
}

variable "app_name" {
  description = "Application name used for all resource naming"
  type        = string
  default     = "failover-app"
}

variable "db_password" {
  description = "RDS PostgreSQL master password"
  type        = string
  sensitive   = true
}

variable "container_image_uri" {
  description = "ECR image URI. If empty, defaults to repository_url:latest"
  type        = string
  default     = ""
}
