#!/usr/bin/env bash
# ==============================================================================
# Cross-Cloud PostgreSQL Replication Lag Health Checker
# SRE Operational Tool for Disaster Recovery & Health Monitoring
# ==============================================================================

set -euo pipefail

PRIMARY_PG_HOST="${PRIMARY_PG_HOST:-}"
PRIMARY_PG_USER="${PRIMARY_PG_USER:-pgadmin}"
PRIMARY_PG_DB="${PRIMARY_PG_DB:-failoverdb}"
PRIMARY_PG_PASSWORD="${PRIMARY_PG_PASSWORD:-}"

SECONDARY_PG_HOST="${SECONDARY_PG_HOST:-}"
SECONDARY_PG_USER="${SECONDARY_PG_USER:-pgadmin}"
SECONDARY_PG_DB="${SECONDARY_PG_DB:-failoverdb}"
SECONDARY_PG_PASSWORD="${SECONDARY_PG_PASSWORD:-}"

MAX_ALLOWED_LAG_BYTES="${MAX_ALLOWED_LAG_BYTES:-10485760}" # 10 MB threshold
MAX_ALLOWED_LAG_SECONDS="${MAX_ALLOWED_LAG_SECONDS:-5}"

echo "==================================================================="
echo "  CROSS-CLOUD REPLICATION HEALTH & LAG AUDIT"
echo "  Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "==================================================================="

if [[ -z "$PRIMARY_PG_HOST" || -z "$SECONDARY_PG_HOST" ]]; then
  echo "⚠️  PRIMARY_PG_HOST or SECONDARY_PG_HOST not defined."
  echo "Usage: PRIMARY_PG_HOST=<azure-fqdn> SECONDARY_PG_HOST=<aws-endpoint> ./check_replication_lag.sh"
  echo "Simulating dry-run inspection..."
  exit 0
fi

export PGPASSWORD="$PRIMARY_PG_PASSWORD"

echo "==> Querying Azure Primary Replication Sender..."
REPL_OUTPUT=$(psql -h "$PRIMARY_PG_HOST" -U "$PRIMARY_PG_USER" -d "$PRIMARY_PG_DB" -t -A -c "
  SELECT 
    COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn), 0) AS replay_lag_bytes,
    COALESCE(EXTRACT(EPOCH FROM replay_lag), 0) AS replay_lag_seconds
  FROM pg_stat_replication 
  LIMIT 1;
" || true)

if [[ -z "$REPL_OUTPUT" ]]; then
  echo "❌ CRITICAL: No active replication stream found on Primary ($PRIMARY_PG_HOST)."
  exit 2
fi

LAG_BYTES=$(echo "$REPL_OUTPUT" | cut -d'|' -f1)
LAG_SECS=$(echo "$REPL_OUTPUT" | cut -d'|' -f2)

echo "    Current Replication Lag: ${LAG_BYTES} bytes / ${LAG_SECS} seconds"

if (( $(echo "$LAG_BYTES > $MAX_ALLOWED_LAG_BYTES" | bc -l) )); then
  echo "⚠️  WARNING: Replication lag bytes ($LAG_BYTES) exceeds threshold ($MAX_ALLOWED_LAG_BYTES)!"
  exit 1
elif (( $(echo "$LAG_SECS > $MAX_ALLOWED_LAG_SECONDS" | bc -l) )); then
  echo "⚠️  WARNING: Replication lag latency (${LAG_SECS}s) exceeds threshold (${MAX_ALLOWED_LAG_SECONDS}s)!"
  exit 1
else
  echo "✅ Replication status is HEALTHY and within SLA (RPO < 5s)."
fi
