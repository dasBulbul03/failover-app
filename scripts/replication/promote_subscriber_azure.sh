#!/usr/bin/env bash
# ==============================================================================
# Script: Promote Azure PostgreSQL Subscriber to Active Primary
# Executed during Failover to Azure
# ==============================================================================

set -euo pipefail

AZURE_PG_HOST="${AZURE_PG_HOST:-}"
DB_USER="${DB_USER:-pgadmin}"
DB_NAME="${DB_NAME:-failoverdb}"
DB_PASSWORD="${DB_PASSWORD:-}"

echo "==================================================================="
echo "  AZURE POSTGRESQL SUBSCRIBER PROMOTION ENGINE"
echo "  Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "==================================================================="

if [[ -z "$AZURE_PG_HOST" ]]; then
  echo "⚠️ AZURE_PG_HOST not set. Looking up via terraform..."
  if command -v terraform >/dev/null 2>&1 && [[ -d "infra/azure" ]]; then
    AZURE_PG_HOST=$(cd infra/azure && terraform output -raw azure_pg_fqdn 2>/dev/null || echo "")
  fi
fi

if [[ -z "$AZURE_PG_HOST" ]]; then
  echo "❌ Error: Could not determine Azure PostgreSQL Host. Pass AZURE_PG_HOST."
  exit 1
fi

echo "==> Target Azure Host: $AZURE_PG_HOST"
echo "==> Executing promotion script (detaching subscription & syncing sequences)..."

export PGPASSWORD="$DB_PASSWORD"
psql -h "$AZURE_PG_HOST" -U "$DB_USER" -d "$DB_NAME" -f "$(dirname "$0")/04_promote_subscriber_azure.sql"

echo "✅ Azure PostgreSQL instance successfully promoted to standalone Primary!"
