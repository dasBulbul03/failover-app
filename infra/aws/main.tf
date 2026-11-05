terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "us-east-1"
}

variable "app_name" {
  default = "failover-app"
}

variable "db_password" {
  sensitive = true
}

variable "container_image_uri" {
  description = "ECR image URI for the app"
}

# ECR Repository
resource "aws_ecr_repository" "app" {
  name                 = var.app_name
  image_tag_mutability = "MUTABLE"
  
  image_scanning_configuration {
    scan_on_push = true
  }
}

# RDS PostgreSQL
resource "aws_db_instance" "postgres" {
  identifier           = "${var.app_name}-pg"
  engine               = "postgres"
  engine_version       = "16"
  instance_class       = "db.t3.micro"
  allocated_storage    = 20
  db_name              = "failoverdb"
  username             = "pgadmin"
  password             = var.db_password
  skip_final_snapshot  = true
  publicly_accessible  = true
  
  tags = {
    Name = "${var.app_name}-postgres"
  }
}

# IAM Role for App Runner
resource "aws_iam_role" "apprunner_role" {
  name = "${var.app_name}-apprunner-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "build.apprunner.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "apprunner_ecr" {
  role       = aws_iam_role.apprunner_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess"
}

# App Runner Service
resource "aws_apprunner_service" "app" {
  service_name = var.app_name

  source_configuration {
    image_repository {
      image_identifier      = var.container_image_uri
      image_repository_type = "ECR"
      image_configuration {
        port = "3000"
        runtime_environment_variables = {
          DATABASE_URL = "postgresql://pgadmin:${var.db_password}@${aws_db_instance.postgres.endpoint}/failoverdb?sslmode=require"
          APP_ENV      = "aws"
          REGION       = var.aws_region
          NODE_ENV     = "production"
        }
      }
    }
    authentication_configuration {
      access_role_arn = aws_iam_role.apprunner_role.arn
    }
    auto_deployments_enabled = true
  }

  health_check_configuration {
    protocol            = "HTTP"
    path                = "/api/health"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 1
    unhealthy_threshold = 5
  }

  instance_configuration {
    cpu    = "1024"
    memory = "2048"
  }

  tags = {
    Name        = var.app_name
    Environment = "aws-secondary"
  }
}

output "app_runner_url" {
  value = "https://${aws_apprunner_service.app.service_url}"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "rds_endpoint" {
  value = aws_db_instance.postgres.endpoint
}
