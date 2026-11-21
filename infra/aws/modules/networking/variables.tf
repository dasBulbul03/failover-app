variable "app_name" {
  type        = string
  description = "Application name"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, prod)"
  default     = "prod"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block"
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  type        = list(string)
  description = "Target Availability Zones"
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "Public Subnet CIDRs (ALB)"
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  type        = list(string)
  description = "Private Subnet CIDRs (ECS Compute)"
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "private_db_subnet_cidrs" {
  type        = list(string)
  description = "Private Database Subnet CIDRs (RDS)"
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

variable "container_port" {
  type        = number
  description = "Application container port"
  default     = 3000
}

variable "enable_nat_gateway" {
  type        = bool
  description = "Deploy NAT Gateway for private egress (FinOps: set false to save ~$32/month in standby)"
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Resource tags"
  default     = {}
}
