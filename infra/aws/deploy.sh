#!/bin/bash
set -e

AWS_REGION="${AWS_REGION:-ap-southeast-2}"
APP_NAME="${APP_NAME:-failover-app}"
DB_PASSWORD="${DB_PASSWORD:-$(openssl rand -base64 16)}"

echo "==> Detecting AWS Account ID..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$APP_NAME"

echo "==> Initializing Terraform..."
terraform init

echo "==> Applying Terraform (Infrastructure & ECR Repository)..."
terraform apply \
  -var="aws_region=$AWS_REGION" \
  -var="app_name=$APP_NAME" \
  -var="db_password=$DB_PASSWORD" \
  -var="container_image_uri=$ECR_URI:latest" \
  -auto-approve

echo "==> Logging in to Amazon ECR..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_URI"

echo "==> Building Docker image (linux/amd64)..."
docker build --platform linux/amd64 -t "$APP_NAME:latest" ../../
docker tag "$APP_NAME:latest" "$ECR_URI:latest"

echo "==> Pushing Docker image to ECR..."
docker push "$ECR_URI:latest"

echo "==> Forcing new deployment on ECS Service..."
aws ecs update-service \
  --cluster failover-cluster \
  --service failover-service \
  --force-new-deployment \
  --region "$AWS_REGION" > /dev/null

echo "==> Deployment Complete!"
terraform output
