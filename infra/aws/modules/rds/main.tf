# ==============================================================================
# Module: Amazon RDS PostgreSQL (High Availability, Logical Replication Ready)
# ==============================================================================

resource "aws_db_subnet_group" "main" {
  name       = "${var.app_name}-${var.environment}-db-subnets"
  subnet_ids = var.subnet_ids

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-db-subnet-group"
  })
}

# Parameter group enabling logical replication for cross-cloud disaster recovery
resource "aws_db_parameter_group" "logical_repl" {
  name   = "${var.app_name}-${var.environment}-pg16-repl"
  family = "postgres16"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "max_replication_slots"
    value        = "10"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "max_wal_senders"
    value        = "10"
    apply_method = "pending-reboot"
  }

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-pg-param-group"
  })
}

resource "aws_db_instance" "postgres" {
  identifier            = "${var.app_name}-${var.environment}-pg"
  engine                = "postgres"
  engine_version        = "16"
  instance_class        = var.instance_class
  allocated_storage     = var.allocated_storage
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  parameter_group_name   = aws_db_parameter_group.logical_repl.name
  vpc_security_group_ids = [var.security_group_id]

  publicly_accessible        = false
  auto_minor_version_upgrade = true
  backup_retention_period    = var.backup_retention_period
  backup_window              = "17:00-18:00"
  maintenance_window         = "Sun:18:00-Sun:19:00"
  deletion_protection        = var.deletion_protection
  skip_final_snapshot        = !var.deletion_protection

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-postgres"
  })
}
