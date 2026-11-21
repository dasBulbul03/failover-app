# ==============================================================================
# Module: IAM Roles (Least-Privilege Roles for ECS Fargate)
# ==============================================================================

# 1. ECS Task Execution Role (used by ECS agent to pull from ECR & stream logs)
resource "aws_iam_role" "ecs_execution" {
  name = "${var.app_name}-${var.environment}-ecsTaskExecutionRole"

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

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-ecs-execution-role"
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# 2. ECS Task Role (used by the application container itself at runtime)
resource "aws_iam_role" "ecs_task" {
  name = "${var.app_name}-${var.environment}-ecsTaskRole"

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

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-ecs-task-role"
  })
}
