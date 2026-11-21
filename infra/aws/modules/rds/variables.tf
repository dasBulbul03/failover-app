variable "app_name" {
  type        = string
  description = "Application name"
}

variable "environment" {
  type        = string
  description = "Deployment environment"
  default     = "prod"
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnet IDs for database subnet group"
}

variable "security_group_id" {
  type        = string
  description = "Security Group ID for RDS"
}

variable "instance_class" {
  type        = string
  description = "Database instance class (FinOps: db.t4g.micro for dev/pilot-light, db.t4g.small for prod)"
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  type        = number
  description = "Allocated storage in GB"
  default     = 20
}

variable "db_name" {
  type        = string
  description = "Database name"
  default     = "failoverdb"
}

variable "db_username" {
  type        = string
  description = "Database master username"
  default     = "pgadmin"
}

variable "db_password" {
  type        = string
  description = "Database master password"
  sensitive   = true
}

variable "backup_retention_period" {
  type        = number
  description = "Days of automated backups to retain"
  default     = 7
}

variable "deletion_protection" {
  type        = bool
  description = "Protect database from accidental deletion"
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Resource tags"
  default     = {}
}
