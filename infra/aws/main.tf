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
  default = "ap-southeast-2"
}

variable "app_name" {
  default = "failover-app"
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
  engine_version       = "16.9"
  instance_class       = "db.t4g.micro"
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

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "failover-cluster"
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.app_name}"
  retention_in_days = 7
}

# Execution Role
resource "aws_iam_role" "ecs_execution" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

output "alb_dns_name" {
  value = "failover-alb-97690356.ap-southeast-2.elb.amazonaws.com"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "rds_endpoint" {
  value = aws_db_instance.postgres.endpoint
}
