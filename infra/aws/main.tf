# ==============================================================================
# AWS Root Infrastructure Module — Multi-Cloud Failover Platform
# Orchestrates: Networking, IAM, ECR, ALB, RDS, ECS Fargate, Monitoring, FinOps
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(var.tags, {
      Project     = var.app_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Role        = "PrimaryCloud"
    })
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
  common_tags = merge(var.tags, {
    Project     = var.app_name
    Environment = var.environment
  })
}

# 1. Networking Layer (VPC, Subnets, Routing, Security Groups)
module "networking" {
  source = "./modules/networking"

  app_name           = var.app_name
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = local.azs
  enable_nat_gateway = var.enable_nat_gateway
  container_port     = var.container_port
  tags               = local.common_tags
}

# 2. IAM Roles (Least-Privilege Execution, Runtime & GitHub OIDC Deploy Roles)
module "iam" {
  source = "./modules/iam"

  app_name          = var.app_name
  environment       = var.environment
  github_repository = var.github_repository
  tags              = local.common_tags
}

# 3. Container Registry (ECR with Lifecycle Cleanup & Scan on Push)
module "ecr" {
  source = "./modules/ecr"

  app_name = var.app_name
  tags     = local.common_tags
}

# 4. Ingress Layer (Application Load Balancer & Health Check Target Group)
module "alb" {
  source = "./modules/alb"

  app_name          = var.app_name
  environment       = var.environment
  vpc_id            = module.networking.vpc_id
  subnet_ids        = module.networking.public_subnet_ids
  security_group_id = module.networking.alb_security_group_id
  container_port    = var.container_port
  health_check_path = "/api/health?probe=readiness"
  tags              = local.common_tags
}

# 5. Database Layer (Amazon RDS PostgreSQL 16 with Logical Replication Enabled)
module "rds" {
  source = "./modules/rds"

  app_name          = var.app_name
  environment       = var.environment
  subnet_ids        = module.networking.private_db_subnet_ids
  security_group_id = module.networking.rds_security_group_id
  db_name           = var.db_name
  db_username       = var.db_username
  db_password       = var.db_password
  instance_class    = var.db_instance_class
  tags              = local.common_tags
}

# 6a. SNS Alarm Topic (CloudWatch alarms → email/PagerDuty)
resource "aws_sns_topic" "alarms" {
  name = "${var.app_name}-${var.environment}-alarms"
  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "alarm_email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# 6b. Observability (CloudWatch Log Group, Alarms, SRE Dashboard)
module "monitoring" {
  source = "./modules/monitoring"

  app_name                = var.app_name
  environment             = var.environment
  ecs_cluster_name        = "${var.app_name}-${var.environment}-cluster"
  ecs_service_name        = "${var.app_name}-service"
  alb_arn_suffix          = replace(module.alb.alb_arn, "/.*loadbalancer\\//", "")
  target_group_arn_suffix = replace(module.alb.target_group_arn, "/.*targetgroup\\//", "")
  rds_identifier          = "${var.app_name}-${var.environment}-pg"
  log_retention_days      = var.log_retention_days
  alarm_sns_topic_arn     = aws_sns_topic.alarms.arn
  tags                    = local.common_tags
}

# 7. Compute Layer (ECS Fargate Task Definition, Service, Autoscaling)
locals {
  active_image = var.container_image_uri != "" ? var.container_image_uri : "${module.ecr.repository_url}:latest"
}

module "ecs" {
  source = "./modules/ecs"

  app_name           = var.app_name
  environment        = var.environment
  ecs_cluster_name   = "${var.app_name}-${var.environment}-cluster"
  aws_region         = var.aws_region
  execution_role_arn = module.iam.execution_role_arn
  task_role_arn      = module.iam.task_role_arn
  container_image    = local.active_image
  container_port     = var.container_port
  cpu                = var.ecs_cpu
  memory             = var.ecs_memory
  desired_count      = var.desired_count
  target_group_arn   = module.alb.target_group_arn
  log_group_name     = module.monitoring.log_group_name

  # For pilot-light without NAT Gateway: run in public subnets with public IP for outbound pulls
  # For enterprise with NAT Gateway: run in private app subnets
  subnet_ids         = var.enable_nat_gateway ? module.networking.private_app_subnet_ids : module.networking.public_subnet_ids
  security_group_ids = [module.networking.ecs_security_group_id]
  assign_public_ip   = !var.enable_nat_gateway

  environment_variables = [
    {
      name  = "DATABASE_URL"
      value = "postgresql://${var.db_username}:${var.db_password}@${module.rds.rds_endpoint}/${var.db_name}?sslmode=require"
    },
    {
      name  = "APP_ENV"
      value = "aws"
    },
    {
      name  = "REGION"
      value = var.aws_region
    },
    {
      name  = "NODE_ENV"
      value = "production"
    }
  ]

  tags = local.common_tags
}

# 8. FinOps (Cloud Cost Budget and Threshold Notifications)
module "finops" {
  source = "./modules/finops"

  app_name                 = var.app_name
  environment              = var.environment
  monthly_budget_limit_usd = var.monthly_budget_limit_usd
  alert_email_addresses    = var.alert_email_addresses
  tags                     = local.common_tags
}
