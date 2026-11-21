#!/usr/bin/env bash
# ==============================================================================
# Azure Deployment Script — Multi-Cloud Failover Platform
# Supports: Terraform (Authoritative Multi-Cloud) and Bicep (Azure CLI Native)
# ==============================================================================

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-failover-rg}"
LOCATION="${LOCATION:-eastus}"
APP_NAME="${APP_NAME:-failover-app}"
PG_PASSWORD="${PG_PASSWORD:-$(openssl rand -base64 16)}"
DEPLOY_ENGINE="${DEPLOY_ENGINE:-terraform}" # Options: terraform, bicep

echo "==================================================================="
echo "  AZURE SECONDARY (DISASTER RECOVERY) INFRASTRUCTURE DEPLOYMENT"
echo "  Engine: $DEPLOY_ENGINE | Location: $LOCATION | RG: $RESOURCE_GROUP"
echo "  Role: Standby Disaster Recovery Cloud (AWS is Primary)"
echo "  Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "==================================================================="

if [[ "$DEPLOY_ENGINE" == "terraform" ]]; then
  echo "==> Deploying via Terraform (Authoritative Multi-Cloud IaC)..."
  terraform init
  terraform apply \
    -var="resource_group_name=$RESOURCE_GROUP" \
    -var="location=$LOCATION" \
    -var="app_name=$APP_NAME" \
    -var="pg_password=$PG_PASSWORD" \
    -auto-approve
  echo "✅ Azure Terraform deployment complete!"
  terraform output
else
  echo "==> Deploying via Azure Bicep Template..."
  echo "Creating resource group: $RESOURCE_GROUP"
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

  az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file main.bicep \
    --parameters appName="$APP_NAME" pgAdminPassword="$PG_PASSWORD" \
    --query "properties.outputs" \
    --output json
  echo "✅ Azure Bicep deployment complete!"
fi

echo "==================================================================="
echo "⚠️  SAVE DATABASE PASSWORD SECURELY:"
echo "    $PG_PASSWORD"
echo "==================================================================="
