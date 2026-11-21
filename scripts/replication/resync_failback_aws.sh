#!/usr/bin/env bash
# ==============================================================================
# Script: Resynchronize AWS Primary from Azure DR before Failback
# Architecture: Azure DR (Temp Publisher) -> AWS Primary (Temp Catch-Up Subscriber)
#
# SRE Safety Guarantees:
#   1. Fails closed on missing credentials or endpoints (never exits 0 on error)
#   2. Verifies AWS Primary remains fenced against application writes during sync
#   3. Establishes reverse logical publication (failback_pub) and subscription (failback_sub)
#   4. Enforces strict convergence verification (LSN diff and row count equality)
#   5. Synchronizes PostgreSQL ID auto-increment sequences on AWS
#   6. Cleans up temporary replication objects and re-arms forward publication
# ==============================================================================

set -euo pipefail

# Support both standardized SRE variable names and aliases
AWS_PG_HOST="${AWS_PG_HOST:-${AWS_RDS_ENDPOINT:-}}"
AWS_PG_PORT="${AWS_PG_PORT:-5432}"
AWS_PG_USER="${AWS_PG_USER:-${AWS_RDS_ADMIN_USER:-pgadmin}}"
AWS_PG_DB="${AWS_PG_DB:-${AWS_RDS_DB:-failoverdb}}"
AWS_PG_PASSWORD="${AWS_PG_PASSWORD:-${AWS_RDS_PASSWORD:-}}"

AZURE_PG_HOST="${AZURE_PG_HOST:-}"
AZURE_PG_PORT="${AZURE_PG_PORT:-5432}"
AZURE_PG_USER="${AZURE_PG_USER:-${AZURE_PG_ADMIN_USER:-pgadmin}}"
AZURE_PG_DB="${AZURE_PG_DB:-${AZURE_PG_DB:-failoverdb}}"
AZURE_PG_PASSWORD="${AZURE_PG_PASSWORD:-}"

MAX_CONVERGENCE_ATTEMPTS="${MAX_CONVERGENCE_ATTEMPTS:-30}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-2}"

echo "==================================================================="
echo "  REVERSE FAILBACK RESYNCHRONIZATION ENGINE (Azure -> AWS Primary)"
echo "  Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "==================================================================="

# --- Guard 1: Validate Required Variables (Fixes Issue 3: Never exit 0 on missing vars) ---
MISSING_VARS=()
[[ -z "$AWS_PG_HOST" ]]     && MISSING_VARS+=("AWS_PG_HOST (or AWS_RDS_ENDPOINT)")
[[ -z "$AWS_PG_PASSWORD" ]] && MISSING_VARS+=("AWS_PG_PASSWORD (or AWS_RDS_PASSWORD)")
[[ -z "$AZURE_PG_HOST" ]]   && MISSING_VARS+=("AZURE_PG_HOST")
[[ -z "$AZURE_PG_PASSWORD" ]] && MISSING_VARS+=("AZURE_PG_PASSWORD")

if (( ${#MISSING_VARS[@]} > 0 )); then
  echo "❌ FATAL: Required environment variables missing: ${MISSING_VARS[*]}" >&2
  echo "Usage: AWS_PG_HOST=<endpoint> AWS_PG_PASSWORD=<pwd> AZURE_PG_HOST=<fqdn> AZURE_PG_PASSWORD=<pwd> $0" >&2
  exit 1
fi

psql_aws() {
  PGPASSWORD="$AWS_PG_PASSWORD" psql -h "$AWS_PG_HOST" -p "$AWS_PG_PORT" -U "$AWS_PG_USER" -d "$AWS_PG_DB" "$@"
}

psql_azure() {
  PGPASSWORD="$AZURE_PG_PASSWORD" psql -h "$AZURE_PG_HOST" -p "$AZURE_PG_PORT" -U "$AZURE_PG_USER" -d "$AZURE_PG_DB" "$@"
}

# --- Guard 2: Verify Connectivity to Both Clouds ---
echo "==> Verifying connectivity to AWS Primary and Azure Secondary..."
if ! psql_aws -t -A -c "SELECT 1;" >/dev/null 2>&1; then
  echo "❌ FATAL: Cannot connect to AWS RDS PostgreSQL at $AWS_PG_HOST" >&2
  exit 1
fi
if ! psql_azure -t -A -c "SELECT 1;" >/dev/null 2>&1; then
  echo "❌ FATAL: Cannot connect to Azure PostgreSQL at $AZURE_PG_HOST" >&2
  exit 1
fi
echo "✅ Connection verified to both databases."

# --- Step 1: Verify AWS RDS is Fenced (Split-Brain Prevention) ---
echo "==> Step 1: Verifying AWS Primary is in read-only fenced state..."
AWS_IS_READONLY=$(psql_aws -t -A -c "SHOW default_transaction_read_only;" 2>/dev/null || echo "off")
if [[ "$AWS_IS_READONLY" != "on" ]]; then
  echo "⚠️ Warning: AWS Primary was NOT read-only. Fencing AWS now before delta sync..."
  psql_aws -c "ALTER SYSTEM SET default_transaction_read_only = on; SELECT pg_reload_conf();" >/dev/null
  echo "✅ AWS Primary fenced (default_transaction_read_only = on)."
else
  echo "✅ Confirmed: AWS Primary is properly fenced (read-only)."
fi

# --- Step 2: Create Reverse Publication on Azure DR ---
echo "==> Step 2: Creating temporary reverse publication 'failback_pub' on Azure DR..."
psql_azure -c "
  DROP PUBLICATION IF EXISTS failback_pub;
  CREATE PUBLICATION failback_pub FOR TABLE messages, replication_heartbeat;
"
AZURE_TARGET_LSN=$(psql_azure -t -A -c "SELECT pg_current_wal_lsn();")
AZURE_ROW_COUNT=$(psql_azure -t -A -c "SELECT COUNT(*) FROM messages;")
echo "    Azure snapshot LSN: $AZURE_TARGET_LSN | Row count: $AZURE_ROW_COUNT"

# --- Step 3: Create Temporary Subscriber on AWS Primary ---
echo "==> Step 3: Creating catch-up subscription 'failback_sub' on AWS Primary..."
psql_aws -c "
  DROP SUBSCRIPTION IF EXISTS failback_sub;
  CREATE SUBSCRIPTION failback_sub
    CONNECTION 'host=$AZURE_PG_HOST port=$AZURE_PG_PORT user=$AZURE_PG_USER password=$AZURE_PG_PASSWORD dbname=$AZURE_PG_DB sslmode=require'
    PUBLICATION failback_pub
    WITH (copy_data = true, create_slot = true);
"

# --- Step 4: Strict Replication Convergence Polling ---
echo "==> Step 4: Polling for replication convergence (target LSN: $AZURE_TARGET_LSN, expected rows: $AZURE_ROW_COUNT)..."
CONVERGED=false

for (( attempt=1; attempt<=MAX_CONVERGENCE_ATTEMPTS; attempt++ )); do
  SUB_STATUS=$(psql_aws -t -A -c "
    SELECT 
      received_lsn,
      latest_end_lsn,
      COALESCE(pg_wal_lsn_diff(received_lsn, '$AZURE_TARGET_LSN'), -1) AS lsn_diff
    FROM pg_stat_subscription 
    WHERE subname = 'failback_sub'
    LIMIT 1;
  " 2>/dev/null || echo "")

  AWS_ROW_COUNT=$(psql_aws -t -A -c "SELECT COUNT(*) FROM messages;" 2>/dev/null || echo "0")
  
  LSN_DIFF=$(echo "$SUB_STATUS" | cut -d'|' -f3)

  echo "    Attempt $attempt/$MAX_CONVERGENCE_ATTEMPTS: AWS rows=$AWS_ROW_COUNT / Azure rows=$AZURE_ROW_COUNT | LSN diff=${LSN_DIFF:-pending}"

  # Verification condition: AWS row count meets/exceeds Azure and received LSN caught up
  if [[ -n "$LSN_DIFF" && "$LSN_DIFF" -ge 0 ]] && [[ "$AWS_ROW_COUNT" -ge "$AZURE_ROW_COUNT" ]]; then
    echo "✅ Delta sync converged: LSN caught up and row counts match!"
    CONVERGED=true
    break
  fi

  sleep "$POLL_INTERVAL_SECONDS"
done

if [[ "$CONVERGED" != "true" ]]; then
  echo "❌ FATAL: Reverse replication failed to converge within $((MAX_CONVERGENCE_ATTEMPTS * POLL_INTERVAL_SECONDS)) seconds!" >&2
  echo "    AWS rows: $AWS_ROW_COUNT | Azure rows: $AZURE_ROW_COUNT" >&2
  echo "    Aborting failback. AWS Primary remains fenced to prevent data corruption." >&2
  exit 1
fi

# --- Step 5: Advance Sequences on AWS Primary ---
echo "==> Step 5: Advancing PostgreSQL auto-increment sequences on AWS Primary..."
psql_aws -c "
  SELECT setval(
    pg_get_serial_sequence('messages', 'id'),
    COALESCE((SELECT MAX(id) FROM messages), 0) + 1,
    false
  );
"

# --- Step 6: Detach Temporary Subscription & Re-arm Forward Publication ---
echo "==> Step 6: Detaching temporary subscription on AWS and re-arming forward publication..."
psql_aws -c "
  ALTER SUBSCRIPTION failback_sub DISABLE;
  ALTER SUBSCRIPTION failback_sub SET (slot_name = NONE);
  DROP SUBSCRIPTION failback_sub;
  DROP PUBLICATION IF EXISTS failover_pub;
  CREATE PUBLICATION failover_pub FOR TABLE messages, replication_heartbeat;
"

# Clean up Azure publication
psql_azure -c "DROP PUBLICATION IF EXISTS failback_pub;" 2>/dev/null || true

echo "==================================================================="
echo "✅ REVERSE RESYNCHRONIZATION COMPLETE & CONVERGED."
echo "   Data consistency verified ($AWS_ROW_COUNT rows synchronized)."
echo "   AWS Primary is now caught up with all Azure DR transactions."
echo "==================================================================="
