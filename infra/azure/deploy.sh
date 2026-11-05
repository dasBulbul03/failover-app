#!/bin/bash
set -e

RESOURCE_GROUP="${RESOURCE_GROUP:-failover-rg}"
LOCATION="${LOCATION:-eastus}"
APP_NAME="${APP_NAME:-failover-app}"
PG_PASSWORD="${PG_PASSWORD:-$(openssl rand -base64 16)}"

echo "Creating resource group: $RESOURCE_GROUP"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

echo "Deploying Azure resources..."
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file main.bicep \
  --parameters appName="$APP_NAME" pgAdminPassword="$PG_PASSWORD" \
  --query "properties.outputs" \
  --output json

echo "Deployment complete!"
echo "PG Password (save this): $PG_PASSWORD"
