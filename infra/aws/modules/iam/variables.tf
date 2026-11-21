variable "app_name" {
  type        = string
  description = "Application name"
}

variable "environment" {
  type        = string
  description = "Deployment environment"
  default     = "prod"
}

variable "tags" {
  type        = map(string)
  description = "Resource tags"
  default     = {}
}
