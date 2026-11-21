# ==============================================================================
# Module: Networking (VPC, Subnets, Routing, Security Groups)
# ==============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-vpc"
  })
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-igw"
  })
}

# --- Public Subnets (ALB & Optional Ingress) ---
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-public-${var.availability_zones[count.index]}"
    Tier = "Public"
  })
}

# --- Private Application Subnets (ECS Compute) ---
resource "aws_subnet" "private_app" {
  count             = length(var.private_app_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_app_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-private-app-${var.availability_zones[count.index]}"
    Tier = "Private-App"
  })
}

# --- Private Database Subnets (Amazon RDS) ---
resource "aws_subnet" "private_db" {
  count             = length(var.private_db_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_db_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-private-db-${var.availability_zones[count.index]}"
    Tier = "Private-DB"
  })
}

# --- Route Tables & Associations ---
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Optional NAT Gateway for strict private application subnet egress
resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"
  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-nat-eip"
  })
}

resource "aws_nat_gateway" "nat" {
  count         = var.enable_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-nat"
  })
  depends_on = [aws_internet_gateway.gw]
}

resource "aws_route_table" "private_app" {
  vpc_id = aws_vpc.main.id

  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.nat[0].id
    }
  }

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-private-app-rt"
  })
}

resource "aws_route_table_association" "private_app" {
  count          = length(aws_subnet.private_app)
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app.id
}

# --- Security Groups (Layered Defense) ---

# 1. ALB Security Group: Ingress 80 (or 443) from Internet
resource "aws_security_group" "alb" {
  name        = "${var.app_name}-${var.environment}-alb-sg"
  description = "Accepts HTTP/HTTPS internet ingress to ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP Ingress"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Egress to all targets"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-alb-sg"
  })
}

# 2. ECS Tasks Security Group: Ingress 3000 ONLY from ALB
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.app_name}-${var.environment}-ecs-tasks-sg"
  description = "Accepts traffic strictly from the ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Inbound from ALB"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Outbound for ECR pulls, CloudWatch, and RDS connectivity"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-ecs-tasks-sg"
  })
}

# 3. RDS PostgreSQL Security Group: Ingress 5432 ONLY from ECS Tasks
resource "aws_security_group" "rds" {
  name        = "${var.app_name}-${var.environment}-rds-sg"
  description = "Accepts PostgreSQL connections strictly from ECS Tasks"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from ECS tasks"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  egress {
    description = "Outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-rds-sg"
  })
}
