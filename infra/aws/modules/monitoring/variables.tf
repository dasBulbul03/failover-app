variable "app_name" {
  type        = string
  description = "Application name"
}

variable "environment" {
  type        = string
  description = "Deployment environment"
  default     = "prod"
}

variable "ecs_cluster_name" {
  type        = string
  description = "ECS Cluster Name"
}

variable "ecs_service_name" {
  type        = string
  description = "ECS Service Name"
}

variable "alb_arn_suffix" {
  type        = string
  description = "ALB ARN Suffix for CloudWatch metrics dimension"
}

variable "target_group_arn_suffix" {
  type        = string
  description = "Target Group ARN Suffix for CloudWatch metrics dimension"
}

variable "rds_identifier" {
  type        = string
  description = "RDS DB Instance Identifier"
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log retention in days (FinOps: 7 days for dev, 14 for prod)"
  default     = 7
}

variable "alarm_sns_topic_arn" {
  type        = string
  description = "SNS topic ARN to send alarm notifications"
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Resource tags"
  default     = {}
}
