variable "app_name" {
  type        = string
  description = "Application name"
}

variable "environment" {
  type        = string
  description = "Deployment environment"
  default     = "prod"
}

variable "monthly_budget_limit_usd" {
  type        = number
  description = "Monthly budget limit in USD"
  default     = 50
}

variable "alert_email_addresses" {
  type        = list(string)
  description = "List of email addresses for budget alerts"
  default     = []
}

variable "tags" {
  type        = map(string)
  description = "Resource tags"
  default     = {}
}
