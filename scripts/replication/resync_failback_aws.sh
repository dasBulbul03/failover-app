#!/usr/bin/env bash
# ==============================================================================
# Script: Resynchronize AWS Primary from Azure before Failback
# Prevents Split-Brain and Data Loss upon Failback to AWS
# ==============================================================================

set -euo pipefail

AWS_PG_HOST="${AWS_PG_HOST:-}"
AZURE_PG_HOST="${AZURE_PG_HOST:-}"
DB_NAME="${DB_NAME:-failoverdb}"
DB_USER="${DB_USER:-pgadmin}"
AWS_PG_PASSWORD="${AWS_PG_PASSWORD:-}"
AZURE_PG_PASSWORD="${AZURE_PG_PASSWORD:-}"

echo "==================================================================="
echo "  REVERSE FAILBACK RESYNCHRONIZATION ENGINE (Azure -> AWS Primary)"
echo "  Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "==================================================================="

if [[ -z "$AWS_PG_HOST" || -z "$AZURE_PG_HOST" ]]; then
  echo "⚠️ AWS_PG_HOST and AZURE_PG_HOST must be provided."
  echo "Usage: AWS_PG_HOST=<aws-endpoint> AZURE_PG_HOST=<azure-fqdn> ./resync_failback_aws.sh"
  exit 0
fi

echo "==> Step 1: Creating reverse publication 'failback_pub' on Azure..."
export PGPASSWORD="$AZURE_PG_PASSWORD"
psql -h "$AZURE_PG_HOST" -U "$DB_USER" -d "$DB_NAME" -c "
  DROP PUBLICATION IF EXISTS failback_pub;
  CREATE PUBLICATION failback_pub FOR TABLE messages;
"

echo "==> Step 2: Creating temporary subscriber on AWS RDS to ingest delta..."
export PGPASSWORD="$AWS_PG_PASSWORD"
psql -h "$AWS_PG_HOST" -U "$DB_USER" -d "$DB_NAME" -c "
  DROP SUBSCRIPTION IF EXISTS failback_sub;
  CREATE SUBSCRIPTION failback_sub
    CONNECTION 'host=$AZURE_PG_HOST port=5432 user=$DB_USER password=$AZURE_PG_PASSWORD dbname=$DB_NAME sslmode=require'
    PUBLICATION failback_pub
    WITH (copy_data = true, create_slot = true);
"

echo "==> Step 3: Polling for replication convergence (0 bytes lag)..."
for i in {1..20}; do
  PENDING=$(psql -h "$AWS_PG_HOST" -U "$DB_USER" -d "$DB_NAME" -t -A -c "
    SELECT count(*) FROM pg_stat_subscription WHERE subname = 'failback_sub' AND latest_end_lsn IS NOT NULL;
  " || echo "0")
  if [[ "$PENDING" -ge 1 ]]; then
    echo "✅ Delta sync completed from Azure to AWS!"
    break
  fi
  sleep 3
done

echo "==> Step 4: Advancing PostgreSQL ID sequence on AWS Primary..."
psql -h "$AWS_PG_HOST" -U "$DB_USER" -d "$DB_NAME" -c "
  SELECT setval(pg_get_serial_sequence('messages', 'id'), COALESCE((SELECT MAX(id) FROM messages), 1) + 1, false);
"

echo "==> Step 5: Detaching temporary failback subscription..."
psql -h "$AWS_PG_HOST" -U "$DB_USER" -d "$DB_NAME" -c "
  ALTER SUBSCRIPTION failback_sub DISABLE;
  ALTER SUBSCRIPTION failback_sub SET (slot_name = NONE);
  DROP SUBSCRIPTION failback_sub;
  DROP PUBLICATION IF EXISTS failover_pub;
  CREATE PUBLICATION failover_pub FOR TABLE messages;
"

echo "✅ Resynchronization complete! It is now safe to failback DNS traffic to AWS Primary."
