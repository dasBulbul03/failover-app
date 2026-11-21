# ==============================================================================
# Module: Amazon ECR (Container Registry with FinOps Lifecycle & Security Scanning)
# ==============================================================================

resource "aws_ecr_repository" "app" {
  name                 = var.app_name
  image_tag_mutability = var.image_tag_mutability

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(var.tags, {
    Name = var.app_name
  })
}

# FinOps: Lifecycle policy to automatically purge obsolete images and untagged builds
resource "aws_ecr_lifecycle_policy" "cleanup" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images older than 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Retain only the last 10 tagged releases"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "sha-", "20"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
