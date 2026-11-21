#!/usr/bin/env bash
# ==============================================================================
# Script: Promote AWS RDS PostgreSQL Subscriber to Active Primary
# Part of Failover Orchestration Pipeline
# ==============================================================================

set -euo pipefail

AWS_RDS_ENDPOINT="${AWS_RDS_ENDPOINT:-}"
DB_USER="${DB_USER:-pgadmin}"
DB_NAME="${DB_NAME:-failoverdb}"
DB_PASSWORD="${DB_PASSWORD:-}"

echo "==================================================================="
echo "  AWS RDS SUBSCRIBER PROMOTION ENGINE"
echo "  Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "==================================================================="

if [[ -z "$AWS_RDS_ENDPOINT" ]]; then
  echo "⚠️ AWS_RDS_ENDPOINT not set. Looking up via terraform / AWS CLI..."
  if command -v terraform >/dev/null 2>&1 && [[ -d "infra/aws" ]]; then
    AWS_RDS_ENDPOINT=$(cd infra/aws && terraform output -raw rds_endpoint 2>/dev/null || echo "")
  fi
fi

if [[ -z "$AWS_RDS_ENDPOINT" ]]; then
  echo "❌ Error: Could not determine AWS RDS Endpoint. Pass AWS_RDS_ENDPOINT."
  exit 1
fi

# Strip port if present in endpoint
HOST="${AWS_RDS_ENDPOINT%%:*}"

echo "==> Target RDS Instance: $HOST"
echo "==> Executing promotion script (detaching subscription & syncing sequences)..."

export PGPASSWORD="$DB_PASSWORD"
psql -h "$HOST" -U "$DB_USER" -d "$DB_NAME" -f "$(dirname "$0")/04_promote_subscriber.sql"

echo "✅ AWS PostgreSQL instance successfully promoted to standalone Primary!"
