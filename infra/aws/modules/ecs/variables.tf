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
  description = "Name for the ECS Cluster"
  default     = ""
}

variable "aws_region" {
  type        = string
  description = "AWS Region"
}

variable "execution_role_arn" {
  type        = string
  description = "IAM Role ARN for ECS Task Execution"
}

variable "task_role_arn" {
  type        = string
  description = "IAM Role ARN for ECS Application Runtime"
}

variable "container_image" {
  type        = string
  description = "Container image URI"
}

variable "container_port" {
  type        = number
  description = "Application port"
  default     = 3000
}

variable "cpu" {
  type        = number
  description = "Task CPU units (256 = 0.25 vCPU)"
  default     = 256
}

variable "memory" {
  type        = number
  description = "Task Memory in MB (512)"
  default     = 512
}

variable "desired_count" {
  type        = number
  description = "Desired number of ECS tasks (FinOps: 1 in warm standby, 0 in cold pilot-light)"
  default     = 1
}

variable "min_capacity" {
  type        = number
  description = "Autoscaling min tasks"
  default     = 1
}

variable "max_capacity" {
  type        = number
  description = "Autoscaling max tasks during failover surge"
  default     = 5
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnet IDs where tasks run"
}

variable "security_group_ids" {
  type        = list(string)
  description = "Security group IDs for tasks"
}

variable "assign_public_ip" {
  type        = bool
  description = "Assign public IP (true when running in public subnets to avoid NAT GW cost)"
  default     = true
}

variable "target_group_arn" {
  type        = string
  description = "ALB Target Group ARN"
}

variable "log_group_name" {
  type        = string
  description = "CloudWatch log group name"
}

variable "environment_variables" {
  type = list(object({
    name  = string
    value = string
  }))
  description = "Environment variables for the container"
  default     = []
}

variable "tags" {
  type        = map(string)
  description = "Resource tags"
  default     = {}
}
