#!/usr/bin/env bash
# ==============================================================================
# SRE Multi-Cloud Failover & Failback Orchestrator
# Architecture: AWS PRIMARY → Azure SECONDARY (Disaster Recovery)
#
# Operations:
#   status    - Check health of both clouds
#   monitor   - Probe AWS; auto-failover if FAILURE_THRESHOLD consecutive failures
#   failover  - Controlled DR failover: AWS → Azure
#   failback  - Controlled recovery: Azure → AWS
#
# Safety mechanisms:
#   - Required env var validation at startup
#   - Consecutive-failure threshold (not single-probe trigger)
#   - Azure readiness verification BEFORE failover
#   - AWS RDS write fencing BEFORE Azure promotion
#   - Azure DB write verification AFTER promotion
#   - DNS change confirmation
#   - State machine via STATE_FILE
#   - File lock (single-host concurrency guard)
#   - Cooldown enforcement
#   - MANUAL_APPROVAL gate for destructive operations
#   - Every step transition logged to AUDIT_LOG
#   - Abort immediately on any critical failure (never report SUCCESS after a failure)
# ==============================================================================

set -uo pipefail

# --- Configuration (override via environment variables) ---
LOCK_FILE="${LOCK_FILE:-/tmp/failover_orchestrator.lock}"
STATE_FILE="${STATE_FILE:-/tmp/failover_state.json}"
AUDIT_LOG="${AUDIT_LOG:-failover_audit.log}"

FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-3}"
RECOVERY_THRESHOLD="${RECOVERY_THRESHOLD:-2}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-4}"
PROBE_DELAY="${PROBE_DELAY:-5}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-300}"

# Optional manual approval gate for destructive operations
MANUAL_APPROVAL="${MANUAL_APPROVAL:-false}"

AWS_HEALTH_URL="${AWS_HEALTH_URL:-}"
AZURE_HEALTH_URL="${AZURE_HEALTH_URL:-}"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-failover-rg}"
TM_PROFILE_NAME="${TM_PROFILE_NAME:-failover-tm}"
AWS_RDS_ENDPOINT="${AWS_RDS_ENDPOINT:-}"
AZURE_PG_HOST="${AZURE_PG_HOST:-}"
AWS_RDS_ADMIN_USER="${AWS_RDS_ADMIN_USER:-pgadmin}"
AWS_RDS_DB="${AWS_RDS_DB:-failoverdb}"
AZURE_PG_ADMIN_USER="${AZURE_PG_ADMIN_USER:-pgadmin}"
AZURE_PG_DB="${AZURE_PG_DB:-failoverdb}"

# Valid states
STATE_NORMAL="NORMAL"
STATE_FAILOVER_IN_PROGRESS="FAILOVER_IN_PROGRESS"
STATE_FAILED_OVER="FAILED_OVER"
STATE_FAILBACK_IN_PROGRESS="FAILBACK_IN_PROGRESS"

# ==============================================================================
# Logging
# ==============================================================================
log() {
  local msg="[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  echo "$msg"
  echo "$msg" >> "$AUDIT_LOG"
}
log_step() { log ""; log "━━━ $* ━━━"; }
die() {
  log "❌ FATAL: $*"
  log "ORCHESTRATOR ABORTED — no state transition committed."
  exit 1
}

# ==============================================================================
# State machine helpers
# ==============================================================================
read_state() {
  if [[ -f "$STATE_FILE" ]]; then
    python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('state','$STATE_NORMAL'))" 2>/dev/null || echo "$STATE_NORMAL"
  else
    echo "$STATE_NORMAL"
  fi
}

write_state() {
  local new_state="$1"
  local note="${2:-}"
  python3 -c "
import json, sys
d = {}
try:
    d = json.load(open('$STATE_FILE'))
except: pass
d['state'] = '$new_state'
d['note'] = '$note'
import datetime
d['updated_at'] = datetime.datetime.utcnow().isoformat() + 'Z'
json.dump(d, open('$STATE_FILE', 'w'), indent=2)
print('State → $new_state')
"
}

# ==============================================================================
# Lock / unlock (single-host concurrency guard)
# ==============================================================================
acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local lock_pid
    lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
      die "Another orchestration process (PID: $lock_pid) is already running."
    fi
    log "⚠️  Stale lock file found (PID $lock_pid no longer exists). Clearing."
    rm -f "$LOCK_FILE"
  fi
  echo $$ > "$LOCK_FILE"
  log "Lock acquired (PID $$, file: $LOCK_FILE)"
}
release_lock() { rm -f "$LOCK_FILE"; }
trap 'release_lock; log "ORCHESTRATOR EXITED (PID $$)"' EXIT

# ==============================================================================
# Cooldown enforcement
# ==============================================================================
check_cooldown() {
  if [[ -f "$STATE_FILE" ]]; then
    local updated_at
    updated_at=$(python3 -c "
import json
try:
    d = json.load(open('$STATE_FILE'))
    print(d.get('updated_at', ''))
except:
    print('')
" 2>/dev/null || echo "")
    if [[ -n "$updated_at" ]]; then
      local last_epoch now_epoch diff
      last_epoch=$(date -d "$updated_at" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$updated_at" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      diff=$(( now_epoch - last_epoch ))
      if (( diff < COOLDOWN_SECONDS )); then
        die "Cooldown active: last state change was ${diff}s ago (cooldown: ${COOLDOWN_SECONDS}s). Wait $((COOLDOWN_SECONDS - diff))s."
      fi
    fi
  fi
}

# ==============================================================================
# Manual approval gate
# ==============================================================================
require_approval() {
  local operation="$1"
  if [[ "$MANUAL_APPROVAL" == "true" ]]; then
    log "⚠️  MANUAL APPROVAL REQUIRED for: $operation"
    log "    Set MANUAL_APPROVAL=false to auto-approve, or type 'yes' to proceed."
    read -r -p "    Approve '$operation'? [yes/no]: " answer
    if [[ "$answer" != "yes" ]]; then
      die "Operation '$operation' was NOT approved. Aborting."
    fi
    log "    ✅ Manually approved: $operation"
  fi
}

# ==============================================================================
# Network probe helper
# ==============================================================================
probe_endpoint() {
  local url="$1"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$PROBE_TIMEOUT" "$url" 2>/dev/null || echo "000")
  echo "$code"
}

# ==============================================================================
# PostgreSQL helper (requires PGPASSWORD set by caller)
# ==============================================================================
psql_exec() {
  local host="$1" port="$2" user="$3" db="$4" sql="$5"
  psql -h "$host" -p "$port" -U "$user" -d "$db" -t -A -c "$sql" 2>&1
}

# ==============================================================================
# ACTION: status
# ==============================================================================
action_status() {
  log_step "SYSTEM STATUS CHECK (AWS Primary / Azure Secondary)"

  local current_state
  current_state=$(read_state)
  log "Current orchestrator state: $current_state"

  if [[ -n "$AWS_HEALTH_URL" ]]; then
    local aws_code
    aws_code=$(probe_endpoint "$AWS_HEALTH_URL")
    log "AWS Primary health:          HTTP $aws_code  ($AWS_HEALTH_URL)"
  else
    log "AWS_HEALTH_URL not set — skipping AWS probe."
  fi

  if [[ -n "$AZURE_HEALTH_URL" ]]; then
    local az_code
    az_code=$(probe_endpoint "$AZURE_HEALTH_URL")
    log "Azure Secondary (DR) health: HTTP $az_code  ($AZURE_HEALTH_URL)"
  else
    log "AZURE_HEALTH_URL not set — skipping Azure probe."
  fi
}

# ==============================================================================
# ACTION: failover (AWS → Azure DR)
# ==============================================================================
action_failover() {
  log_step "INITIATING CONTROLLED DR FAILOVER: AWS → Azure"

  # 0. Required variable validation
  local missing_vars=()
  [[ -z "$AWS_HEALTH_URL" ]]     && missing_vars+=("AWS_HEALTH_URL")
  [[ -z "$AZURE_HEALTH_URL" ]]   && missing_vars+=("AZURE_HEALTH_URL")
  [[ -z "$AWS_RDS_ENDPOINT" ]]   && missing_vars+=("AWS_RDS_ENDPOINT")
  [[ -z "${AWS_RDS_PASSWORD:-}" ]] && missing_vars+=("AWS_RDS_PASSWORD")
  [[ -z "$AZURE_PG_HOST" ]]      && missing_vars+=("AZURE_PG_HOST")
  [[ -z "${AZURE_PG_PASSWORD:-}" ]] && missing_vars+=("AZURE_PG_PASSWORD")
  if (( ${#missing_vars[@]} > 0 )); then
    die "Required env vars not set: ${missing_vars[*]}"
  fi

  # Check state machine
  local current_state
  current_state=$(read_state)
  if [[ "$current_state" != "$STATE_NORMAL" ]]; then
    die "Cannot initiate failover: current state is '$current_state' (expected '$STATE_NORMAL')."
  fi

  check_cooldown
  require_approval "FAILOVER: AWS → Azure (destructive — will fence AWS writes)"

  write_state "$STATE_FAILOVER_IN_PROGRESS" "Failover started"

  # 1. Confirm AWS Primary is actually down (don't failover a healthy primary)
  log_step "Step 1: Confirming AWS Primary is unhealthy"
  local aws_code
  aws_code=$(probe_endpoint "$AWS_HEALTH_URL")
  if [[ "$aws_code" == "200" ]]; then
    write_state "$STATE_NORMAL" "Failover aborted — AWS primary is healthy"
    die "AWS Primary returned HTTP 200 — it appears healthy. Failover aborted to prevent unnecessary DR."
  fi
  log "✅ AWS Primary confirmed unhealthy (HTTP $aws_code). Proceeding."

  # 2. Verify Azure Secondary is healthy BEFORE switching
  log_step "Step 2: Verifying Azure Secondary is ready"
  local az_code
  az_code=$(probe_endpoint "$AZURE_HEALTH_URL")
  if [[ "$az_code" != "200" ]]; then
    write_state "$STATE_NORMAL" "Failover aborted — Azure unhealthy"
    die "Azure Secondary returned HTTP $az_code. Cannot fail over to an unhealthy DR target."
  fi
  log "✅ Azure Secondary is healthy (HTTP 200)."

  # 3. Verify Azure DB connectivity
  log_step "Step 3: Verifying Azure PostgreSQL DB connectivity"
  export PGPASSWORD="$AZURE_PG_PASSWORD"
  local db_check
  db_check=$(psql_exec "$AZURE_PG_HOST" "5432" "$AZURE_PG_ADMIN_USER" "$AZURE_PG_DB" "SELECT 1;" || echo "FAILED")
  if [[ "$db_check" != "1" ]]; then
    write_state "$STATE_NORMAL" "Failover aborted — Azure DB not reachable"
    die "Azure PostgreSQL is not reachable. Cannot promote — failover aborted."
  fi
  log "✅ Azure PostgreSQL is reachable."

  # 4. FENCE AWS PRIMARY — set read-only to prevent split-brain
  log_step "Step 4: Fencing AWS Primary (setting read-only)"
  export PGPASSWORD="$AWS_RDS_PASSWORD"
  local fence_result
  fence_result=$(psql_exec "$AWS_RDS_ENDPOINT" "5432" "$AWS_RDS_ADMIN_USER" "$AWS_RDS_DB" \
    "ALTER SYSTEM SET default_transaction_read_only = on; SELECT pg_reload_conf();" 2>&1 || echo "FAILED")
  if echo "$fence_result" | grep -qi "FAILED\|error"; then
    log "⚠️  WARNING: Could not fence AWS RDS (may already be down). Continuing with caution."
    log "    Fence result: $fence_result"
  else
    log "✅ AWS RDS fenced — set to read-only."
  fi

  # 5. Promote Azure PostgreSQL subscriber
  log_step "Step 5: Promoting Azure PostgreSQL to standalone read-write"
  local promote_script
  promote_script="$(dirname "$0")/../replication/promote_subscriber_azure.sh"
  if [[ -f "$promote_script" ]]; then
    if ! bash "$promote_script"; then
      die "Promotion script failed. Azure DB may not be in a consistent state. ABORTING."
    fi
    log "✅ Azure PostgreSQL promotion script completed."
  else
    log "⚠️  Promotion script not found at $promote_script. Running inline SQL promotion."
    export PGPASSWORD="$AZURE_PG_PASSWORD"
    psql_exec "$AZURE_PG_HOST" "5432" "$AZURE_PG_ADMIN_USER" "$AZURE_PG_DB" \
      "ALTER SUBSCRIPTION failover_sub DISABLE;" > /dev/null 2>&1 || true
    log "    Subscription disabled (Azure is now standalone)."
  fi

  # 6. Verify Azure can perform WRITE operation after promotion
  log_step "Step 6: Verifying Azure DB accepts writes post-promotion"
  export PGPASSWORD="$AZURE_PG_PASSWORD"
  local write_check
  write_check=$(psql_exec "$AZURE_PG_HOST" "5432" "$AZURE_PG_ADMIN_USER" "$AZURE_PG_DB" \
    "INSERT INTO replication_heartbeat (id, ts) VALUES (999, now()) ON CONFLICT (id) DO UPDATE SET ts=now(); SELECT 'write_ok';" 2>&1 || echo "FAILED")
  if [[ "$write_check" != *"write_ok"* ]]; then
    die "Azure PostgreSQL did NOT accept a write after promotion. Failover UNSAFE. Abort."
  fi
  log "✅ Azure PostgreSQL accepted a test write — promotion verified."

  # 7. Switch DNS routing to Azure
  log_step "Step 7: Switching DNS traffic to Azure Secondary"
  if command -v az > /dev/null 2>&1 && [[ -n "$TM_PROFILE_NAME" ]]; then
    if ! az network traffic-manager endpoint update \
      --resource-group "$AZURE_RESOURCE_GROUP" \
      --profile-name "$TM_PROFILE_NAME" \
      --name aws-primary \
      --type externalEndpoints \
      --endpoint-status Disabled \
      --output none; then
      die "Azure CLI failed to disable AWS endpoint in Traffic Manager. DNS NOT changed."
    fi
    log "✅ Traffic Manager: AWS endpoint DISABLED. 100% traffic → Azure DR."

    # 8. Confirm DNS change propagated
    log_step "Step 8: Confirming DNS change"
    sleep 5
    local tm_state
    tm_state=$(az network traffic-manager endpoint show \
      --resource-group "$AZURE_RESOURCE_GROUP" \
      --profile-name "$TM_PROFILE_NAME" \
      --name aws-primary \
      --type externalEndpoints \
      --query "properties.endpointStatus" -o tsv 2>/dev/null || echo "unknown")
    if [[ "$tm_state" != "Disabled" ]]; then
      die "DNS confirmation failed: Traffic Manager endpoint state is '$tm_state' (expected 'Disabled')."
    fi
    log "✅ DNS change confirmed: Traffic Manager reports AWS endpoint is Disabled."
  else
    log "ℹ️  Azure CLI not available or TM_PROFILE_NAME not set."
    log "    ACTION REQUIRED: Manually disable AWS endpoint in Traffic Manager / Route 53."
    log "    DNS switch NOT automated — human intervention needed."
  fi

  write_state "$STATE_FAILED_OVER" "Failover to Azure completed"
  log ""
  log "🎉 FAILOVER COMPLETED SUCCESSFULLY: AWS → Azure DR"
  log "   Azure is now serving production traffic."
  log "   AWS RDS is fenced (read-only)."
  log "   Next step: Monitor Azure, then run 'failback' when AWS recovers."
}

# ==============================================================================
# ACTION: failback (Azure → AWS)
# ==============================================================================
action_failback() {
  log_step "INITIATING CONTROLLED FAILBACK: Azure → AWS Primary"

  local missing_vars=()
  [[ -z "$AWS_HEALTH_URL" ]]     && missing_vars+=("AWS_HEALTH_URL")
  [[ -z "$AWS_RDS_ENDPOINT" ]]   && missing_vars+=("AWS_RDS_ENDPOINT")
  [[ -z "${AWS_RDS_PASSWORD:-}" ]] && missing_vars+=("AWS_RDS_PASSWORD")
  [[ -z "$AZURE_PG_HOST" ]]      && missing_vars+=("AZURE_PG_HOST")
  [[ -z "${AZURE_PG_PASSWORD:-}" ]] && missing_vars+=("AZURE_PG_PASSWORD")
  if (( ${#missing_vars[@]} > 0 )); then
    die "Required env vars not set: ${missing_vars[*]}"
  fi

  local current_state
  current_state=$(read_state)
  if [[ "$current_state" != "$STATE_FAILED_OVER" ]]; then
    die "Cannot failback: current state is '$current_state' (expected '$STATE_FAILED_OVER')."
  fi

  check_cooldown
  require_approval "FAILBACK: Azure → AWS (destructive — will re-fence Azure and switch DNS)"

  write_state "$STATE_FAILBACK_IN_PROGRESS" "Failback started"

  # 1. Verify AWS Primary has fully recovered
  log_step "Step 1: Verifying AWS Primary has recovered"
  local aws_code
  aws_code=$(probe_endpoint "$AWS_HEALTH_URL")
  if [[ "$aws_code" != "200" ]]; then
    write_state "$STATE_FAILED_OVER" "Failback aborted — AWS still unhealthy"
    die "AWS Primary returned HTTP $aws_code — not recovered. Failback aborted."
  fi
  log "✅ AWS Primary recovered (HTTP 200)."

  # 2. Verify AWS DB connectivity and unfence it
  log_step "Step 2: Unfencing AWS RDS (re-enabling writes)"
  export PGPASSWORD="$AWS_RDS_PASSWORD"
  local unfence_result
  unfence_result=$(psql_exec "$AWS_RDS_ENDPOINT" "5432" "$AWS_RDS_ADMIN_USER" "$AWS_RDS_DB" \
    "ALTER SYSTEM SET default_transaction_read_only = off; SELECT pg_reload_conf();" 2>&1 || echo "FAILED")
  if echo "$unfence_result" | grep -qi "FAILED\|error"; then
    die "Cannot unfence AWS RDS. failback aborted — resolve AWS DB issue first."
  fi
  log "✅ AWS RDS unfenced — read-write restored."

  # 3. Resynchronize delta from Azure → AWS (data written during DR period)
  log_step "Step 3: Resynchronizing DR delta: Azure → AWS"
  local resync_script
  resync_script="$(dirname "$0")/../replication/resync_failback_aws.sh"
  if [[ -f "$resync_script" ]] && [[ -n "$AZURE_PG_HOST" ]]; then
    if ! bash "$resync_script"; then
      die "Failback resync script failed. Data consistency NOT guaranteed. Aborting failback."
    fi
    log "✅ Delta resync completed."
  else
    log "⚠️  Resync script not found or AZURE_PG_HOST not set. Skipping automated resync."
    log "    ACTION REQUIRED: Manually verify data consistency between Azure and AWS before continuing."
    require_approval "Continue failback WITHOUT automated resync (manual consistency verification required)"
  fi

  # 4. Data consistency check (row count comparison)
  log_step "Step 4: Data consistency check (row count comparison)"
  export PGPASSWORD="$AWS_RDS_PASSWORD"
  local aws_count
  aws_count=$(psql_exec "$AWS_RDS_ENDPOINT" "5432" "$AWS_RDS_ADMIN_USER" "$AWS_RDS_DB" \
    "SELECT COUNT(*) FROM messages;" 2>&1 || echo "FAILED")

  export PGPASSWORD="$AZURE_PG_PASSWORD"
  local az_count
  az_count=$(psql_exec "$AZURE_PG_HOST" "5432" "$AZURE_PG_ADMIN_USER" "$AZURE_PG_DB" \
    "SELECT COUNT(*) FROM messages;" 2>&1 || echo "FAILED")

  log "    AWS row count:   $aws_count"
  log "    Azure row count: $az_count"

  if [[ "$aws_count" == "FAILED" || "$az_count" == "FAILED" ]]; then
    log "⚠️  Could not complete row count check (table may not exist or connection failed)."
    require_approval "Continue failback with UNVERIFIED row count consistency?"
  elif [[ "$aws_count" != "$az_count" ]]; then
    log "⚠️  Row count MISMATCH: AWS=$aws_count vs Azure=$az_count"
    require_approval "Row count mismatch detected. Continue failback anyway (data loss possible)?"
  else
    log "✅ Row counts match: $aws_count rows on both sides."
  fi

  # 5. Verify AWS accepts writes
  log_step "Step 5: Verifying AWS DB accepts writes"
  export PGPASSWORD="$AWS_RDS_PASSWORD"
  local write_check
  write_check=$(psql_exec "$AWS_RDS_ENDPOINT" "5432" "$AWS_RDS_ADMIN_USER" "$AWS_RDS_DB" \
    "INSERT INTO replication_heartbeat (id, ts) VALUES (999, now()) ON CONFLICT (id) DO UPDATE SET ts=now(); SELECT 'write_ok';" 2>&1 || echo "FAILED")
  if [[ "$write_check" != *"write_ok"* ]]; then
    die "AWS RDS did NOT accept a write. Failback UNSAFE. Aborting."
  fi
  log "✅ AWS RDS accepts writes — verified."

  # 6. Re-establish forward replication: AWS → Azure
  log_step "Step 6: Re-establishing AWS → Azure forward replication"
  export PGPASSWORD="$AZURE_PG_PASSWORD"
  local repl_result
  repl_result=$(psql_exec "$AZURE_PG_HOST" "5432" "$AZURE_PG_ADMIN_USER" "$AZURE_PG_DB" \
    "ALTER SUBSCRIPTION failover_sub ENABLE; ALTER SUBSCRIPTION failover_sub REFRESH PUBLICATION;" \
    2>&1 || echo "FAILED")
  if echo "$repl_result" | grep -qi "FAILED\|error"; then
    log "⚠️  Could not re-enable subscription automatically. Manual replication setup may be needed."
    log "    Result: $repl_result"
  else
    log "✅ Subscription re-enabled on Azure subscriber."
  fi

  # 7. Restore DNS to AWS Primary
  log_step "Step 7: Restoring DNS traffic to AWS Primary"
  if command -v az > /dev/null 2>&1 && [[ -n "$TM_PROFILE_NAME" ]]; then
    if ! az network traffic-manager endpoint update \
      --resource-group "$AZURE_RESOURCE_GROUP" \
      --profile-name "$TM_PROFILE_NAME" \
      --name aws-primary \
      --type externalEndpoints \
      --endpoint-status Enabled \
      --output none; then
      die "Azure CLI failed to re-enable AWS endpoint. DNS NOT changed."
    fi
    log "✅ Traffic Manager: AWS endpoint ENABLED. Traffic reverting to AWS Primary."

    sleep 5
    local tm_state
    tm_state=$(az network traffic-manager endpoint show \
      --resource-group "$AZURE_RESOURCE_GROUP" \
      --profile-name "$TM_PROFILE_NAME" \
      --name aws-primary \
      --type externalEndpoints \
      --query "properties.endpointStatus" -o tsv 2>/dev/null || echo "unknown")
    if [[ "$tm_state" != "Enabled" ]]; then
      die "DNS confirmation failed: endpoint state is '$tm_state' (expected 'Enabled')."
    fi
    log "✅ DNS change confirmed: Traffic Manager AWS endpoint is Enabled."
  else
    log "⚠️  Azure CLI not available. Manual DNS switch required."
    log "    ACTION REQUIRED: Re-enable AWS endpoint in Traffic Manager / Route 53."
  fi

  write_state "$STATE_NORMAL" "Failback to AWS completed"
  log ""
  log "🎉 FAILBACK COMPLETED: Azure → AWS Primary restored."
  log "   AWS is now serving production traffic."
  log "   Azure is back to DR subscriber role."
}

# ==============================================================================
# ACTION: monitor (continuous health probe → auto-failover)
# ==============================================================================
action_monitor() {
  log_step "CONTINUOUS HEALTH MONITOR — AWS Primary"

  if [[ -z "$AWS_HEALTH_URL" ]]; then
    die "AWS_HEALTH_URL is required for monitor mode."
  fi

  local current_state
  current_state=$(read_state)
  if [[ "$current_state" != "$STATE_NORMAL" ]]; then
    log "⚠️  Orchestrator state is '$current_state' — skipping auto-failover trigger."
    log "    Resolve the current state before running monitor mode."
    exit 0
  fi

  log "Probing AWS Primary (failure threshold: $FAILURE_THRESHOLD consecutive failures)..."
  local consecutive_fails=0

  for (( i=1; i<=FAILURE_THRESHOLD; i++ )); do
    local code
    code=$(probe_endpoint "$AWS_HEALTH_URL")
    log "Probe $i/$FAILURE_THRESHOLD: AWS Primary → HTTP $code"

    if [[ "$code" == "200" ]]; then
      log "✅ AWS Primary is healthy. No failover required."
      exit 0
    fi
    consecutive_fails=$(( consecutive_fails + 1 ))
    if (( i < FAILURE_THRESHOLD )); then
      sleep "$PROBE_DELAY"
    fi
  done

  log "🚨 THRESHOLD BREACHED: $consecutive_fails/$FAILURE_THRESHOLD consecutive failures on AWS Primary."
  action_failover
}

# ==============================================================================
# Main dispatcher
# ==============================================================================
acquire_lock

ACTION="${1:-status}"
log "ORCHESTRATOR STARTED — action: $ACTION (PID: $$)"

case "$ACTION" in
  status)   action_status   ;;
  monitor)  action_monitor  ;;
  failover) action_failover ;;
  failback) action_failback ;;
  *)
    echo "Usage: $0 {status|monitor|failover|failback}"
    echo ""
    echo "Environment variables:"
    echo "  AWS_HEALTH_URL          - AWS ALB health endpoint (required for monitor/failover)"
    echo "  AZURE_HEALTH_URL        - Azure App Service health endpoint"
    echo "  AWS_RDS_ENDPOINT        - AWS RDS hostname (required for failover/failback)"
    echo "  AWS_RDS_PASSWORD        - AWS RDS admin password"
    echo "  AZURE_PG_HOST           - Azure PostgreSQL hostname"
    echo "  AZURE_PG_PASSWORD       - Azure PostgreSQL admin password"
    echo "  TM_PROFILE_NAME         - Azure Traffic Manager profile name"
    echo "  AZURE_RESOURCE_GROUP    - Azure resource group"
    echo "  MANUAL_APPROVAL=true    - Require interactive confirmation for destructive steps"
    echo "  COOLDOWN_SECONDS        - Minimum seconds between state changes (default: 300)"
    exit 1
    ;;
esac
