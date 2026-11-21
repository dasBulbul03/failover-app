# Multi-Cloud DNS Failover Setup Guide
## Architecture: AWS (Primary) → Azure (Secondary Disaster Recovery)

This guide covers configuring DNS-based active-passive failover with **Amazon Web Services as PRIMARY** and **Microsoft Azure as SECONDARY (Disaster Recovery)**.

---

## Overview

```
User / Client Traffic
         │
         ▼
Global DNS Router (Azure Traffic Manager / AWS Route 53)
         ├─ PRIMARY (Priority 1)   → AWS Application Load Balancer (Sydney ap-southeast-2)
         └─ SECONDARY (Priority 2) → Azure App Service (East US - Activated on AWS failure)
```

Health Probe: `GET /api/health?probe=readiness` → Expected HTTP 200

---

## Method 1: Azure Traffic Manager (Priority Routing)

### Step-by-Step CLI Configuration

```bash
RESOURCE_GROUP="failover-rg"
PROFILE_NAME="failover-tm"
AWS_ALB_FQDN="failover-alb-97690356.ap-southeast-2.elb.amazonaws.com"
AZURE_APP_FQDN="<your-app-name>.azurewebsites.net"

# 1. Create Traffic Manager Profile (Priority Routing, 60s TTL)
az network traffic-manager profile create \
  --name "$PROFILE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --routing-method Priority \
  --unique-dns-name "failover-app-global" \
  --ttl 60 \
  --protocol HTTP \
  --port 80 \
  --path "/api/health?probe=readiness"

# 2. Add AWS Application Load Balancer as PRIMARY (Priority 1)
az network traffic-manager endpoint create \
  --name aws-primary \
  --profile-name "$PROFILE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --type externalEndpoints \
  --target "$AWS_ALB_FQDN" \
  --priority 1 \
  --endpoint-status Enabled

# 3. Add Azure App Service as SECONDARY / STANDBY (Priority 2)
az network traffic-manager endpoint create \
  --name azure-secondary \
  --profile-name "$PROFILE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --type externalEndpoints \
  --target "$AZURE_APP_FQDN" \
  --priority 2 \
  --endpoint-status Enabled
```

---

## Method 2: AWS Route 53 (Failover Routing Policy)

If using AWS Route 53 as the authoritative DNS manager:

### Step 1: Create Route 53 Health Checks

```bash
# 1. Health check for AWS Primary ALB
aws route53 create-health-check \
  --caller-reference "aws-primary-$(date +%s)" \
  --health-check-config '{
    "Type": "HTTP",
    "FullyQualifiedDomainName": "failover-alb-97690356.ap-southeast-2.elb.amazonaws.com",
    "Port": 80,
    "ResourcePath": "/api/health?probe=readiness",
    "RequestInterval": 10,
    "FailureThreshold": 3
  }'

# 2. Health check for Azure Secondary Web App
aws route53 create-health-check \
  --caller-reference "azure-secondary-$(date +%s)" \
  --health-check-config '{
    "Type": "HTTPS",
    "FullyQualifiedDomainName": "<your-app>.azurewebsites.net",
    "Port": 443,
    "ResourcePath": "/api/health?probe=readiness",
    "RequestInterval": 30,
    "FailureThreshold": 3
  }'
```

### Step 2: Configure Failover DNS Record Sets

In your Hosted Zone:
1. **Primary Record**:
   - Name: `app.yourdomain.com`
   - Type: `CNAME`
   - Routing Policy: **Failover**
   - Failover Record Type: **Primary**
   - Target: `failover-alb-97690356.ap-southeast-2.elb.amazonaws.com`
   - Health Check: Associated with AWS Health Check ID
   - TTL: 60s

2. **Secondary Record**:
   - Name: `app.yourdomain.com`
   - Type: `CNAME`
   - Routing Policy: **Failover**
   - Failover Record Type: **Secondary**
   - Target: `<your-app>.azurewebsites.net`
   - Health Check: Associated with Azure Health Check ID
   - TTL: 60s
