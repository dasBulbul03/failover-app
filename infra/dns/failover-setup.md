# DNS Failover Setup Guide

This guide covers two approaches to configure DNS-based failover between Azure (primary) and AWS (secondary) for the failover-app.

---

## Overview

```
User → DNS (Traffic Manager / Route 53)
         ├─ PRIMARY  → Azure App Service  (priority 1)
         └─ SECONDARY → AWS App Runner   (priority 2, activated on primary failure)
```

Health probe endpoint: `GET /api/health` → expected HTTP 200

---

## Method 1: Azure Traffic Manager (Recommended)

Azure Traffic Manager uses **Priority routing** — all traffic goes to the primary endpoint; the secondary only receives traffic when the primary health check fails.

### Prerequisites
- Azure CLI installed and logged in (`az login`)
- Both Azure Web App and AWS App Runner deployed
- Your domain's DNS managed or delegatable to Traffic Manager CNAME

### Step-by-step with Azure CLI

```bash
RESOURCE_GROUP="failover-rg"
PROFILE_NAME="failover-tm"
AZURE_APP_FQDN="<your-azure-webapp>.azurewebsites.net"   # from Bicep output: webAppUrl
AWS_APP_FQDN="<your-apprunner-id>.awsapprunner.com"      # from Terraform output: app_runner_url

# 1. Create Traffic Manager profile (priority routing, TTL 60s)
az network traffic-manager profile create \
  --name "$PROFILE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --routing-method Priority \
  --unique-dns-name failover-app \
  --ttl 60 \
  --protocol HTTPS \
  --port 443 \
  --path /api/health

# 2. Add Azure App Service as PRIMARY endpoint (priority 1)
az network traffic-manager endpoint create \
  --name azure-primary \
  --profile-name "$PROFILE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --type externalEndpoints \
  --target "$AZURE_APP_FQDN" \
  --priority 1 \
  --endpoint-status Enabled

# 3. Add AWS App Runner as SECONDARY endpoint (priority 2)
az network traffic-manager endpoint create \
  --name aws-secondary \
  --profile-name "$PROFILE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --type externalEndpoints \
  --target "$AWS_APP_FQDN" \
  --priority 2 \
  --endpoint-status Enabled

# 4. View the Traffic Manager FQDN (point your domain's CNAME here)
az network traffic-manager profile show \
  --name "$PROFILE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "dnsConfig.fqdn" \
  --output tsv
```

### DNS Configuration

After running the commands above, create a **CNAME** record in your DNS registrar:

| Record | Type  | Value                                    | TTL |
|--------|-------|------------------------------------------|-----|
| `@` or `www` | CNAME | `failover-app.trafficmanager.net` | 60s |

### Health Probe Settings

Traffic Manager is configured with:
- **Protocol**: HTTPS
- **Port**: 443
- **Path**: `/api/health`
- **Probe interval**: 30 seconds (default)
- **Tolerated failures**: 3 (default — failover triggers after ~90s)

To adjust the probe interval to 10 seconds (faster failover, requires Standard tier):
```bash
az network traffic-manager profile update \
  --name "$PROFILE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --monitor-interval 10 \
  --monitor-timeout 5 \
  --monitor-tolerated-failures 2
```

### Verify & Monitor

```bash
# Check endpoint health status
az network traffic-manager endpoint show \
  --name azure-primary \
  --profile-name "$PROFILE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --type externalEndpoints \
  --query "properties.endpointMonitorStatus"

# List all endpoints and their status
az network traffic-manager endpoint list \
  --profile-name "$PROFILE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --output table
```

---

## Method 2: AWS Route 53 Failover Routing

Route 53 **Failover routing policy** sends traffic to the PRIMARY record; if its health check fails, traffic automatically shifts to the SECONDARY record.

### Prerequisites
- AWS CLI installed and configured (`aws configure`)
- Your domain hosted in Route 53 (or delegated to it)
- Hosted Zone ID for your domain

### Step-by-step with AWS CLI

```bash
HOSTED_ZONE_ID="Z1234567890ABC"              # Your Route 53 Hosted Zone ID
DOMAIN="app.yourdomain.com"
AZURE_APP_FQDN="<your-azure-webapp>.azurewebsites.net"
AWS_APP_FQDN="<your-apprunner-id>.awsapprunner.com"

# 1. Create a health check for the Azure (primary) endpoint
HEALTH_CHECK_ID=$(aws route53 create-health-check \
  --caller-reference "azure-primary-$(date +%s)" \
  --health-check-config '{
    "FullyQualifiedDomainName": "'"$AZURE_APP_FQDN"'",
    "Port": 443,
    "Type": "HTTPS",
    "ResourcePath": "/api/health",
    "RequestInterval": 30,
    "FailureThreshold": 3
  }' \
  --query "HealthCheck.Id" \
  --output text)

echo "Health Check ID: $HEALTH_CHECK_ID"

# 2. Create PRIMARY failover CNAME record → Azure App Service
aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch '{
    "Changes": [
      {
        "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": "'"$DOMAIN"'",
          "Type": "CNAME",
          "SetIdentifier": "azure-primary",
          "Failover": "PRIMARY",
          "TTL": 60,
          "ResourceRecords": [{"Value": "'"$AZURE_APP_FQDN"'"}],
          "HealthCheckId": "'"$HEALTH_CHECK_ID"'"
        }
      }
    ]
  }'

# 3. Create SECONDARY failover CNAME record → AWS App Runner
aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch '{
    "Changes": [
      {
        "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": "'"$DOMAIN"'",
          "Type": "CNAME",
          "SetIdentifier": "aws-secondary",
          "Failover": "SECONDARY",
          "TTL": 60,
          "ResourceRecords": [{"Value": "'"$AWS_APP_FQDN"'"}]
        }
      }
    ]
  }'
```

### Verify Health Check Status

```bash
# Check health check status
aws route53 get-health-check-status \
  --health-check-id "$HEALTH_CHECK_ID" \
  --query "HealthCheckObservations[*].{Region:Region,Status:StatusReport.Status}" \
  --output table

# List all resource record sets for your domain
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${DOMAIN}.']" \
  --output table
```

### DNS Configuration

If your domain registrar is **not** Route 53, delegate the subdomain by adding NS records pointing to your Route 53 hosted zone's name servers:

```bash
# Get your hosted zone's name servers
aws route53 get-hosted-zone \
  --id "$HOSTED_ZONE_ID" \
  --query "DelegationSet.NameServers" \
  --output text
```

---

## Comparison

| Feature | Azure Traffic Manager | AWS Route 53 |
|---|---|---|
| Routing method | Priority | Failover |
| Health probe interval | 30s (10s with Standard) | 10s or 30s |
| Failover time (approx.) | ~90s default | ~90s default |
| TTL | 60s | 60s |
| Cost | Per profile + per million queries | Per health check + per million queries |
| Best when primary is | Azure App Service | Either cloud |

> [!TIP]
> Use **Azure Traffic Manager** when your primary deployment is on Azure — it integrates natively with App Service resources and supports ARM-based endpoint management.
> Use **AWS Route 53** when your team is more AWS-centric or you need advanced routing features like geolocation or latency-based routing alongside failover.

> [!IMPORTANT]
> Ensure your `/api/health` endpoint returns HTTP **200** when healthy. Both Traffic Manager and Route 53 health checkers will mark an endpoint as unhealthy on any non-2xx response or connection timeout.
