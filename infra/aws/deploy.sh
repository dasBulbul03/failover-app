#!/bin/bash
set -e

AWS_REGION="${AWS_REGION:-us-east-1}"
APP_NAME="${APP_NAME:-failover-app}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$APP_NAME"
DB_PASSWORD="${DB_PASSWORD:-$(openssl rand -base64 16)}"

echo "=== Building and pushing Docker image ==="
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_URI" 2>/dev/null || true

# Initialize terraform first to create ECR, then push image
terraform init
terraform apply -var="aws_region=$AWS_REGION" -var="db_password=$DB_PASSWORD" -var="container_image_uri=$ECR_URI:latest" -auto-approve

echo "=== Building Docker image ==="
docker build -t "$APP_NAME" ../../
docker tag "$APP_NAME:latest" "$ECR_URI:latest"

echo "=== Pushing to ECR ==="
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_URI"
docker push "$ECR_URI:latest"

echo "Deployment complete!"
