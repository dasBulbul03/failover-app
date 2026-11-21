# ==============================================================================
# Azure Primary Infrastructure — Multi-Cloud Failover Platform
# AUTHORITATIVE IAC FOR AZURE
# Provisions: App Service, PostgreSQL Flexible Server (Logical Replication),
#             Key Vault, Managed Identity, Log Analytics
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.90"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}

data "azurerm_client_config" "current" {}

variable "resource_group_name" {
  type        = string
  description = "Name of the Azure Resource Group"
  default     = "failover-rg"
}

variable "location" {
  type        = string
  description = "Azure primary region (e.g., eastus)"
  default     = "eastus"
}

variable "app_name" {
  type        = string
  description = "Base application name"
  default     = "failover-app"
}

variable "pg_password" {
  type        = string
  description = "PostgreSQL administrator password"
  sensitive   = true
}

variable "tags" {
  type        = map(string)
  description = "Resource tags"
  default = {
    Project     = "failover-app"
    Environment = "prod"
    Role        = "PrimaryCloud"
    ManagedBy   = "Terraform"
  }
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# 1. Resource Group
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# 2. Managed Identity
resource "azurerm_user_assigned_identity" "app_identity" {
  name                = "${var.app_name}-identity"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  tags                = var.tags
}

# 3. Log Analytics Workspace for Monitoring
resource "azurerm_log_analytics_workspace" "logs" {
  name                = "${var.app_name}-law-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# 4. Azure Key Vault (Secure DB Password Storage)
resource "azurerm_key_vault" "kv" {
  name                       = "${var.app_name}-kv-${random_string.suffix.result}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id
    secret_permissions = [
      "Get", "List", "Set", "Delete", "Purge"
    ]
  }

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = azurerm_user_assigned_identity.app_identity.principal_id
    secret_permissions = [
      "Get"
    ]
  }

  tags = var.tags
}

resource "azurerm_key_vault_secret" "pg_password" {
  name         = "database-password"
  value        = var.pg_password
  key_vault_id = azurerm_key_vault.kv.id
}

# 5. Linux App Service Plan
resource "azurerm_service_plan" "plan" {
  name                = "${var.app_name}-plan"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "B1" # FinOps: Basic 1 vCPU, 1.75 GB RAM
  tags                = var.tags
}

# 6. Azure Database for PostgreSQL Flexible Server
resource "azurerm_postgresql_flexible_server" "pg" {
  name                   = "${var.app_name}-pg-${random_string.suffix.result}"
  resource_group_name    = azurerm_resource_group.rg.name
  location               = azurerm_resource_group.rg.location
  version                = "16"
  administrator_login    = "pgadmin"
  administrator_password = var.pg_password
  storage_mb             = 32768
  sku_name               = "B_Standard_B1ms"
  backup_retention_days  = 7
  tags                   = var.tags
}

# Enable Logical Replication on Azure PostgreSQL for Cross-Cloud Sync
resource "azurerm_postgresql_flexible_server_configuration" "replication" {
  name      = "azure.replication_support"
  server_id = azurerm_postgresql_flexible_server.pg.id
  value     = "logical"
}

resource "azurerm_postgresql_flexible_server_database" "db" {
  name      = "failoverdb"
  server_id = azurerm_postgresql_flexible_server.pg.id
  collation = "en_US.utf8"
  charset   = "utf8"
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure" {
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.pg.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# 7. Linux Web App (Containerized Next.js App)
resource "azurerm_linux_web_app" "app" {
  name                = "${var.app_name}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  service_plan_id     = azurerm_service_plan.plan.id
  https_only          = true

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app_identity.id]
  }

  site_config {
    always_on         = true
    health_check_path = "/api/health?probe=readiness"
    application_stack {
      node_version = "20-lts"
    }
  }

  app_settings = {
    DATABASE_URL = "postgresql://pgadmin:${var.pg_password}@${azurerm_postgresql_flexible_server.pg.fqdn}:5432/failoverdb?sslmode=require"
    APP_ENV      = "azure"
    REGION       = var.location
    NODE_ENV     = "production"
  }

  tags = var.tags
}

output "azure_app_url" {
  description = "Public URL for Azure Web App"
  value       = "https://${azurerm_linux_web_app.app.default_hostname}"
}

output "azure_health_url" {
  description = "Health Check Probe URL for Traffic Manager"
  value       = "https://${azurerm_linux_web_app.app.default_hostname}/api/health?probe=readiness"
}

output "azure_pg_fqdn" {
  description = "PostgreSQL Flexible Server FQDN"
  value       = azurerm_postgresql_flexible_server.pg.fqdn
}

output "key_vault_name" {
  description = "Azure Key Vault Name"
  value       = azurerm_key_vault.kv.name
}
