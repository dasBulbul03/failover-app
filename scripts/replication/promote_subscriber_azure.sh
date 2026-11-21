#!/usr/bin/env bash
# ==============================================================================
# Script: Promote Azure PostgreSQL Subscriber to Standalone Read-Write Primary
# Executed during Disaster Recovery Failover to Azure Secondary
# Architecture: AWS Primary (Fenced) -> Azure Secondary (Promoted)
# ==============================================================================

set -euo pipefail

# Support both standardized SRE variable names and legacy aliases
AZURE_PG_HOST="${AZURE_PG_HOST:-}"
AZURE_PG_PORT="${AZURE_PG_PORT:-5432}"
AZURE_PG_ADMIN_USER="${AZURE_PG_ADMIN_USER:-${DB_USER:-pgadmin}}"
AZURE_PG_DB="${AZURE_PG_DB:-${DB_NAME:-failoverdb}}"
AZURE_PG_PASSWORD="${AZURE_PG_PASSWORD:-${DB_PASSWORD:-}}"

echo "==================================================================="
echo "  AZURE POSTGRESQL SUBSCRIBER PROMOTION ENGINE"
echo "  Role: Secondary DR Cloud -> Standalone Primary"
echo "  Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "==================================================================="

# --- Guard 1: Verify Host ---
if [[ -z "$AZURE_PG_HOST" ]]; then
  echo "⚠️ AZURE_PG_HOST not set in environment. Checking Terraform outputs..." >&2
  if command -v terraform >/dev/null 2>&1 && [[ -d "infra/azure" ]]; then
    AZURE_PG_HOST=$(cd infra/azure && terraform output -raw azure_pg_fqdn 2>/dev/null || echo "")
  fi
fi

if [[ -z "$AZURE_PG_HOST" ]]; then
  echo "❌ FATAL: Could not determine Azure PostgreSQL Host. Set AZURE_PG_HOST." >&2
  exit 1
fi

# --- Guard 2: Verify Password (Fixes Issue 1) ---
if [[ -z "$AZURE_PG_PASSWORD" ]]; then
  echo "❌ FATAL: Database credentials missing! Set AZURE_PG_PASSWORD (or DB_PASSWORD)." >&2
  exit 1
fi

echo "==> Target Azure Host: $AZURE_PG_HOST:$AZURE_PG_PORT (Database: $AZURE_PG_DB, User: $AZURE_PG_ADMIN_USER)"
echo "==> Executing subscriber detachment and sequence synchronization..."

export PGPASSWORD="$AZURE_PG_PASSWORD"

SQL_FILE="$(dirname "$0")/04_promote_subscriber_azure.sql"
if [[ ! -f "$SQL_FILE" ]]; then
  echo "❌ FATAL: Promotion SQL file not found at $SQL_FILE" >&2
  exit 1
fi

if ! psql -h "$AZURE_PG_HOST" -p "$AZURE_PG_PORT" -U "$AZURE_PG_ADMIN_USER" -d "$AZURE_PG_DB" -f "$SQL_FILE"; then
  echo "❌ FATAL: Promotion SQL script execution failed!" >&2
  exit 1
fi

# --- Verification: Confirm Azure Accepts Writes ---
echo "==> Verifying promoted Azure database accepts writes..."
TEST_WRITE=$(psql -h "$AZURE_PG_HOST" -p "$AZURE_PG_PORT" -U "$AZURE_PG_ADMIN_USER" -d "$AZURE_PG_DB" -t -A -c "
  INSERT INTO replication_heartbeat (id, ts) VALUES (1, NOW())
  ON CONFLICT (id) DO UPDATE SET ts = NOW();
  SELECT 'PROMOTION_VERIFIED';
" 2>&1 || echo "FAILED")

if [[ "$TEST_WRITE" != *"PROMOTION_VERIFIED"* ]]; then
  echo "❌ FATAL: Azure PostgreSQL failed write verification after promotion!" >&2
  echo "Output: $TEST_WRITE" >&2
  exit 1
fi

echo "✅ Azure PostgreSQL instance successfully promoted and verified read-write standalone Primary!"
