#!/usr/bin/env bash
# ==============================================================================
# AWS Modular Deployment Pipeline Script
# Builds, Provisions via Terraform, and Ships to ECS Fargate
# ==============================================================================

set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-southeast-2}"
APP_NAME="${APP_NAME:-failover-app}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
DB_PASSWORD="${DB_PASSWORD:-$(openssl rand -base64 16)}"

echo "==================================================================="
echo "  FAILOVERAPP AWS INFRASTRUCTURE & CONTAINER DEPLOYMENT"
echo "  Region: $AWS_REGION | Environment: $ENVIRONMENT"
echo "  Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "==================================================================="

echo "==> Step 1: Querying AWS Caller Identity..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$APP_NAME"

echo "==> Step 2: Initializing Modular Terraform..."
terraform init

echo "==> Step 3: Applying Terraform Infrastructure..."
terraform apply \
  -var="aws_region=$AWS_REGION" \
  -var="environment=$ENVIRONMENT" \
  -var="app_name=$APP_NAME" \
  -var="db_password=$DB_PASSWORD" \
  -var="container_image_uri=$ECR_URI:latest" \
  -auto-approve

echo "==> Step 4: Authenticating Docker with Amazon ECR..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_URI"

echo "==> Step 5: Building multi-arch container image (linux/amd64)..."
docker build --platform linux/amd64 -t "$APP_NAME:latest" ../../
docker tag "$APP_NAME:latest" "$ECR_URI:latest"
docker tag "$APP_NAME:latest" "$ECR_URI:$(git rev-parse --short HEAD 2>/dev/null || echo 'latest')"

echo "==> Step 6: Pushing image to Amazon ECR..."
docker push "$ECR_URI:latest"
docker push "$ECR_URI:$(git rev-parse --short HEAD 2>/dev/null || echo 'latest')"

CLUSTER_NAME=$(terraform output -raw ecs_cluster_name 2>/dev/null || echo "failover-cluster")
SERVICE_NAME=$(terraform output -raw ecs_service_name 2>/dev/null || echo "failover-service")

echo "==> Step 7: Triggering ECS Zero-Downtime Rolling Deployment..."
aws ecs update-service \
  --cluster "$CLUSTER_NAME" \
  --service "$SERVICE_NAME" \
  --force-new-deployment \
  --region "$AWS_REGION" > /dev/null

echo "==================================================================="
echo "✅ AWS DEPLOYMENT COMPLETE!"
echo "==================================================================="
terraform output
