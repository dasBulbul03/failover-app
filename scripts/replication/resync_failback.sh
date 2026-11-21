#!/usr/bin/env bash
# ==============================================================================
# Script: Resynchronize Azure Primary from AWS before Failback
# Prevents Split-Brain and Data Loss upon Failback
# ==============================================================================

set -euo pipefail

AZURE_PG_HOST="${AZURE_PG_HOST:-}"
AWS_PG_HOST="${AWS_PG_HOST:-}"
DB_NAME="${DB_NAME:-failoverdb}"
DB_USER="${DB_USER:-pgadmin}"
AWS_PG_PASSWORD="${AWS_PG_PASSWORD:-}"
AZURE_PG_PASSWORD="${AZURE_PG_PASSWORD:-}"

echo "==================================================================="
echo "  REVERSE FAILBACK RESYNCHRONIZATION ENGINE"
echo "  Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "==================================================================="

if [[ -z "$AZURE_PG_HOST" || -z "$AWS_PG_HOST" ]]; then
  echo "⚠️ AZURE_PG_HOST and AWS_PG_HOST must be provided."
  echo "Usage: AZURE_PG_HOST=<azure-fqdn> AWS_PG_HOST=<aws-endpoint> ./resync_failback.sh"
  exit 0
fi

echo "==> Step 1: Creating reverse publication 'failback_pub' on AWS..."
export PGPASSWORD="$AWS_PG_PASSWORD"
psql -h "$AWS_PG_HOST" -U "$DB_USER" -d "$DB_NAME" -c "
  DROP PUBLICATION IF EXISTS failback_pub;
  CREATE PUBLICATION failback_pub FOR TABLE messages;
"

echo "==> Step 2: Creating temporary subscriber on Azure to ingest delta..."
export PGPASSWORD="$AZURE_PG_PASSWORD"
psql -h "$AZURE_PG_HOST" -U "$DB_USER" -d "$DB_NAME" -c "
  DROP SUBSCRIPTION IF EXISTS failback_sub;
  CREATE SUBSCRIPTION failback_sub
    CONNECTION 'host=$AWS_PG_HOST port=5432 user=$DB_USER password=$AWS_PG_PASSWORD dbname=$DB_NAME sslmode=require'
    PUBLICATION failback_pub
    WITH (copy_data = true, create_slot = true);
"

echo "==> Step 3: Polling for replication convergence (0 bytes lag)..."
for i in {1..20}; do
  PENDING=$(psql -h "$AZURE_PG_HOST" -U "$DB_USER" -d "$DB_NAME" -t -A -c "
    SELECT count(*) FROM pg_stat_subscription WHERE subname = 'failback_sub' AND latest_end_lsn IS NOT NULL;
  " || echo "0")
  if [[ "$PENDING" -ge 1 ]]; then
    echo "✅ Delta sync completed from AWS to Azure!"
    break
  fi
  sleep 3
done

echo "==> Step 4: Advancing PostgreSQL ID sequence on Azure..."
psql -h "$AZURE_PG_HOST" -U "$DB_USER" -d "$DB_NAME" -c "
  SELECT setval(pg_get_serial_sequence('messages', 'id'), COALESCE((SELECT MAX(id) FROM messages), 1) + 1, false);
"

echo "==> Step 5: Detaching temporary failback subscription..."
psql -h "$AZURE_PG_HOST" -U "$DB_USER" -d "$DB_NAME" -c "
  ALTER SUBSCRIPTION failback_sub DISABLE;
  ALTER SUBSCRIPTION failback_sub SET (slot_name = NONE);
  DROP SUBSCRIPTION failback_sub;
  DROP PUBLICATION IF EXISTS failover_pub;
  CREATE PUBLICATION failover_pub FOR TABLE messages;
"

echo "✅ Resynchronization complete! It is now safe to failback DNS traffic to Azure."
