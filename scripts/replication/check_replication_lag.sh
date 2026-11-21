#!/usr/bin/env bash
# ==============================================================================
# Cross-Cloud PostgreSQL Logical Replication Lag Health Checker
# Architecture: AWS RDS (Publisher/Primary) → Azure PostgreSQL (Subscriber/DR)
#
# IMPORTANT — Logical vs Physical replication metrics:
#   Physical replication: pg_stat_replication (standby view on PRIMARY)
#   Logical replication:  pg_stat_subscription (subscription view on SUBSCRIBER)
#
# This script uses BOTH sides for a complete picture:
#   1. Publisher (AWS): pg_replication_slots — slot activity and retained WAL
#   2. Subscriber (Azure): pg_stat_subscription — received/applied positions
#   3. Heartbeat table: replication_heartbeat — freshness check (most reliable)
#
# Replication states this script reports:
#   UNKNOWN       - credentials or hosts not provided
#   DISCONNECTED  - no active slot on publisher OR subscription not running
#   LAG_EXCEEDED  - freshness heartbeat older than MAX_ALLOWED_LAG_SECONDS
#   HEALTHY       - subscription active and heartbeat within threshold
# ==============================================================================

set -uo pipefail

# --- Configuration ---
AWS_PG_HOST="${AWS_PG_HOST:-}"
AWS_PG_PORT="${AWS_PG_PORT:-5432}"
AWS_PG_USER="${AWS_PG_USER:-pgadmin}"
AWS_PG_DB="${AWS_PG_DB:-failoverdb}"
AWS_PG_PASSWORD="${AWS_PG_PASSWORD:-}"

AZURE_PG_HOST="${AZURE_PG_HOST:-}"
AZURE_PG_PORT="${AZURE_PG_PORT:-5432}"
AZURE_PG_USER="${AZURE_PG_USER:-pgadmin}"
AZURE_PG_DB="${AZURE_PG_DB:-failoverdb}"
AZURE_PG_PASSWORD="${AZURE_PG_PASSWORD:-}"

PUBLICATION_NAME="${PUBLICATION_NAME:-failover_pub}"
SUBSCRIPTION_NAME="${SUBSCRIPTION_NAME:-failover_sub}"
REPLICATION_SLOT_NAME="${REPLICATION_SLOT_NAME:-failover_sub}"

# Max seconds since last heartbeat before we declare LAG_EXCEEDED
MAX_ALLOWED_LAG_SECONDS="${MAX_ALLOWED_LAG_SECONDS:-30}"

REPLICATION_STATUS="UNKNOWN"

# --- Output helpers ---
log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"; }
pass() { log "✅ $*"; }
warn() { log "⚠️  $*"; }
fail() { log "❌ $*"; }

echo "==================================================================="
echo "  LOGICAL REPLICATION HEALTH CHECK"
echo "  Publisher (AWS RDS) → Subscriber (Azure PostgreSQL)"
echo "  Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "==================================================================="

# --- Guard: require credentials ---
if [[ -z "$AWS_PG_HOST" || -z "$AWS_PG_PASSWORD" ]]; then
  fail "ABORT: AWS_PG_HOST or AWS_PG_PASSWORD not set — cannot check publisher."
  echo "STATUS: UNKNOWN"
  exit 2
fi
if [[ -z "$AZURE_PG_HOST" || -z "$AZURE_PG_PASSWORD" ]]; then
  fail "ABORT: AZURE_PG_HOST or AZURE_PG_PASSWORD not set — cannot check subscriber."
  echo "STATUS: UNKNOWN"
  exit 2
fi

# --- Step 1: Check Publisher (AWS) — Replication Slot Activity ---
log "==> Step 1: Checking AWS Publisher replication slot..."
export PGPASSWORD="$AWS_PG_PASSWORD"

SLOT_OUTPUT=$(psql \
  -h "$AWS_PG_HOST" -p "$AWS_PG_PORT" \
  -U "$AWS_PG_USER" -d "$AWS_PG_DB" \
  -t -A -c "
    SELECT
      slot_name,
      active,
      plugin,
      pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS retained_wal,
      COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn), 0)    AS retained_wal_bytes
    FROM pg_replication_slots
    WHERE slot_name = '$REPLICATION_SLOT_NAME'
    LIMIT 1;
  " 2>&1 || echo "QUERY_FAILED")

if [[ "$SLOT_OUTPUT" == "QUERY_FAILED" || -z "$SLOT_OUTPUT" ]]; then
  fail "Cannot connect to AWS publisher or slot '$REPLICATION_SLOT_NAME' does not exist."
  REPLICATION_STATUS="DISCONNECTED"
else
  SLOT_ACTIVE=$(echo "$SLOT_OUTPUT" | cut -d'|' -f2)
  RETAINED_WAL=$(echo "$SLOT_OUTPUT" | cut -d'|' -f4)
  RETAINED_WAL_BYTES=$(echo "$SLOT_OUTPUT" | cut -d'|' -f5)

  if [[ "$SLOT_ACTIVE" == "t" ]]; then
    pass "Publisher slot '$REPLICATION_SLOT_NAME' is ACTIVE. Retained WAL: $RETAINED_WAL"
    REPLICATION_STATUS="ACTIVE"
  else
    warn "Publisher slot '$REPLICATION_SLOT_NAME' exists but is INACTIVE (subscriber not connected)."
    REPLICATION_STATUS="DISCONNECTED"
  fi
fi

# Check publication exists on publisher
PUB_CHECK=$(psql \
  -h "$AWS_PG_HOST" -p "$AWS_PG_PORT" \
  -U "$AWS_PG_USER" -d "$AWS_PG_DB" \
  -t -A -c "SELECT pubname FROM pg_publication WHERE pubname='$PUBLICATION_NAME';" 2>&1 || echo "")
if [[ -z "$PUB_CHECK" ]]; then
  warn "Publication '$PUBLICATION_NAME' not found on AWS publisher."
else
  pass "Publication '$PUBLICATION_NAME' exists on AWS publisher."
fi

# --- Step 2: Check Subscriber (Azure) — Subscription State ---
log "==> Step 2: Checking Azure Subscriber subscription state..."
unset PGPASSWORD
export PGPASSWORD="$AZURE_PG_PASSWORD"

SUB_OUTPUT=$(psql \
  -h "$AZURE_PG_HOST" -p "$AZURE_PG_PORT" \
  -U "$AZURE_PG_USER" -d "$AZURE_PG_DB" \
  -t -A -c "
    SELECT
      subname,
      subenabled,
      worker_pid,
      last_msg_send_time,
      last_msg_receipt_time,
      EXTRACT(EPOCH FROM (now() - last_msg_receipt_time))::int AS seconds_since_last_msg,
      latest_end_lsn,
      received_lsn
    FROM pg_stat_subscription
    WHERE subname = '$SUBSCRIPTION_NAME'
    LIMIT 1;
  " 2>&1 || echo "QUERY_FAILED")

if [[ "$SUB_OUTPUT" == "QUERY_FAILED" || -z "$SUB_OUTPUT" ]]; then
  fail "Cannot query Azure subscriber or subscription '$SUBSCRIPTION_NAME' does not exist."
  REPLICATION_STATUS="DISCONNECTED"
else
  SUB_ENABLED=$(echo "$SUB_OUTPUT" | cut -d'|' -f2)
  WORKER_PID=$(echo "$SUB_OUTPUT" | cut -d'|' -f3)
  SECS_SINCE_MSG=$(echo "$SUB_OUTPUT" | cut -d'|' -f6)
  RECEIVED_LSN=$(echo "$SUB_OUTPUT" | cut -d'|' -f8)

  log "    Subscription enabled: $SUB_ENABLED | Worker PID: ${WORKER_PID:-none} | Received LSN: $RECEIVED_LSN"
  log "    Seconds since last WAL message: ${SECS_SINCE_MSG:-unknown}"

  if [[ "$SUB_ENABLED" != "t" ]]; then
    warn "Subscription '$SUBSCRIPTION_NAME' is DISABLED on Azure subscriber."
    REPLICATION_STATUS="DISCONNECTED"
  elif [[ -z "$WORKER_PID" ]]; then
    warn "Subscription worker not running (no worker PID). Replication may be stalled."
    REPLICATION_STATUS="DISCONNECTED"
  else
    pass "Subscription '$SUBSCRIPTION_NAME' is active with worker PID $WORKER_PID."
    if [[ -n "$SECS_SINCE_MSG" ]] && (( SECS_SINCE_MSG > MAX_ALLOWED_LAG_SECONDS )); then
      warn "Last WAL message was ${SECS_SINCE_MSG}s ago (threshold: ${MAX_ALLOWED_LAG_SECONDS}s)."
      REPLICATION_STATUS="LAG_EXCEEDED"
    fi
  fi
fi

# --- Step 3: Heartbeat Freshness Check (most reliable lag indicator) ---
log "==> Step 3: Checking heartbeat table freshness on Azure subscriber..."

# Try to read the heartbeat row that the publisher writes periodically.
# This requires a heartbeat table: CREATE TABLE replication_heartbeat (id INT PRIMARY KEY, ts TIMESTAMPTZ);
HEARTBEAT=$(psql \
  -h "$AZURE_PG_HOST" -p "$AZURE_PG_PORT" \
  -U "$AZURE_PG_USER" -d "$AZURE_PG_DB" \
  -t -A -c "
    SELECT
      EXTRACT(EPOCH FROM (now() - ts))::int AS lag_seconds,
      ts
    FROM replication_heartbeat
    WHERE id = 1;
  " 2>&1 || echo "QUERY_FAILED")

if [[ "$HEARTBEAT" == "QUERY_FAILED" || -z "$HEARTBEAT" ]]; then
  warn "Heartbeat table not found or no row. Run scripts/replication/01_setup_publisher_aws.sql to create it."
  warn "Heartbeat check SKIPPED — relying on pg_stat_subscription data only."
else
  HB_LAG=$(echo "$HEARTBEAT" | cut -d'|' -f1)
  HB_TS=$(echo "$HEARTBEAT" | cut -d'|' -f2)
  log "    Last heartbeat received at: $HB_TS (${HB_LAG}s ago)"

  if (( HB_LAG > MAX_ALLOWED_LAG_SECONDS )); then
    warn "HEARTBEAT LAG: ${HB_LAG}s exceeds threshold (${MAX_ALLOWED_LAG_SECONDS}s)!"
    REPLICATION_STATUS="LAG_EXCEEDED"
  elif [[ "$REPLICATION_STATUS" == "ACTIVE" ]]; then
    REPLICATION_STATUS="HEALTHY"
    pass "Heartbeat freshness OK: ${HB_LAG}s lag (threshold: ${MAX_ALLOWED_LAG_SECONDS}s)"
  fi
fi

# --- Summary ---
echo ""
echo "==================================================================="
echo "  REPLICATION STATUS: $REPLICATION_STATUS"
echo "==================================================================="

case "$REPLICATION_STATUS" in
  HEALTHY)
    pass "Replication is HEALTHY. RPO is within target."
    exit 0
    ;;
  LAG_EXCEEDED)
    warn "Replication lag EXCEEDS threshold. Investigate immediately."
    exit 1
    ;;
  DISCONNECTED)
    fail "Replication is DISCONNECTED. Azure subscriber is not receiving WAL."
    exit 2
    ;;
  ACTIVE)
    # Active slot but heartbeat table missing — treat as partially healthy
    warn "Replication slot active but heartbeat table not set up. Status: ACTIVE (unverified freshness)."
    exit 0
    ;;
  UNKNOWN|*)
    fail "Replication status UNKNOWN — credentials missing or publisher unreachable."
    exit 3
    ;;
esac
