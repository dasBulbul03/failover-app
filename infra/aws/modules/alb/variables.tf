variable "app_name" {
  type        = string
  description = "Application name"
}

variable "environment" {
  type        = string
  description = "Deployment environment"
  default     = "prod"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID where the target group resides"
}

variable "subnet_ids" {
  type        = list(string)
  description = "Public subnet IDs where ALB is deployed"
}

variable "security_group_id" {
  type        = string
  description = "Security Group ID for ALB"
}

variable "container_port" {
  type        = number
  description = "Target application container port"
  default     = 3000
}

variable "health_check_path" {
  type        = string
  description = "Path for ALB health check probe"
  default     = "/api/health"
}

variable "enable_deletion_protection" {
  type        = bool
  description = "Enable deletion protection on ALB"
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Resource tags"
  default     = {}
}
