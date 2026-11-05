terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "resource_group_name" {
  default = "failover-rg"
}

variable "location" {
  default = "eastus"
}

variable "app_name" {
  default = "failover-app"
}

variable "pg_password" {
  type      = string
  sensitive = true
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# App Service Plan (Linux)
resource "azurerm_service_plan" "plan" {
  name                = "${var.app_name}-plan"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "B1"
}

# Azure Database for PostgreSQL Flexible Server
resource "azurerm_postgresql_flexible_server" "pg" {
  name                   = "${var.app_name}-pg-${random_string.suffix.result}"
  resource_group_name    = azurerm_resource_group.rg.name
  location               = azurerm_resource_group.rg.location
  version                = "16"
  administrator_login    = "pgadmin"
  administrator_password = var.pg_password
  storage_mb             = 32768
  sku_name               = "B_Standard_B1ms"
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
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

# Azure App Service (Linux Web App)
resource "azurerm_linux_web_app" "app" {
  name                = "${var.app_name}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  service_plan_id     = azurerm_service_plan.plan.id

  site_config {
    always_on = true
    application_stack {
      node_version = "20-lts"
    }
    health_check_path = "/api/health"
  }

  app_settings = {
    DATABASE_URL = "postgresql://pgadmin:${var.pg_password}@${azurerm_postgresql_flexible_server.pg.fqdn}:5432/failoverdb?sslmode=require"
    APP_ENV      = "azure"
    REGION       = var.location
    NODE_ENV     = "production"
  }
}

output "azure_app_url" {
  value = "https://${azurerm_linux_web_app.app.default_hostname}"
}
