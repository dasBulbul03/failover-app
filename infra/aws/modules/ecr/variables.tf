variable "app_name" {
  type        = string
  description = "ECR repository name"
}

variable "image_tag_mutability" {
  type        = string
  description = "Tag mutability setting (MUTABLE or IMMUTABLE)"
  default     = "MUTABLE"
}

variable "tags" {
  type        = map(string)
  description = "Resource tags"
  default     = {}
}
