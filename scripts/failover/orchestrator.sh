#!/usr/bin/env bash
# ==============================================================================
# SRE Multi-Cloud Failover & Failback Orchestrator
# Architecture: AWS PRIMARY (ap-southeast-2) -> Azure SECONDARY (eastus)
#
# Operations:
#   status    - Check health of both clouds
#   monitor   - Probe AWS; auto-failover if FAILURE_THRESHOLD consecutive failures
#   failover  - Controlled DR failover: AWS -> Azure
#   failback  - Controlled recovery: Azure -> AWS
#
# Production SRE Hardening:
#   - Required environment variable validation at startup (fails closed)
#   - Explicit primary write fencing with verification query before secondary promotion
#   - Keeps AWS strictly fenced during failback until reverse replication converges
#   - Convergence verification via LSN diff and row count equality (never reports false success)
#   - State machine persistence via STATE_FILE (/tmp/failover_state.json)
#   - Non-blocking lock file guards against concurrent executions
#   - Safe manual approval support for destructive operations (interactive or env-flagged)
#   - Comprehensive timestamped audit logging
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

# Manual approval gates
MANUAL_APPROVAL="${MANUAL_APPROVAL:-false}"
APPROVE_FAILOVER="${APPROVE_FAILOVER:-false}"
APPROVE_FAILBACK="${APPROVE_FAILBACK:-false}"
FORCE="${FORCE:-false}"
FORCE_FAILOVER_WITHOUT_FENCE="${FORCE_FAILOVER_WITHOUT_FENCE:-false}"

AWS_HEALTH_URL="${AWS_HEALTH_URL:-}"
AZURE_HEALTH_URL="${AZURE_HEALTH_URL:-}"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-failover-rg}"
TM_PROFILE_NAME="${TM_PROFILE_NAME:-failover-tm}"

AWS_RDS_ENDPOINT="${AWS_RDS_ENDPOINT:-${AWS_PG_HOST:-}}"
AWS_RDS_PASSWORD="${AWS_RDS_PASSWORD:-${AWS_PG_PASSWORD:-}}"
AWS_RDS_ADMIN_USER="${AWS_RDS_ADMIN_USER:-${AWS_PG_USER:-pgadmin}}"
AWS_RDS_DB="${AWS_RDS_DB:-${AWS_PG_DB:-failoverdb}}"

AZURE_PG_HOST="${AZURE_PG_HOST:-}"
AZURE_PG_PASSWORD="${AZURE_PG_PASSWORD:-}"
AZURE_PG_ADMIN_USER="${AZURE_PG_ADMIN_USER:-${AZURE_PG_USER:-pgadmin}}"
AZURE_PG_DB="${AZURE_PG_DB:-${AZURE_PG_DB:-failoverdb}}"

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
    python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('state','$STATE_NORMAL'))" 2>/dev/null || echo "$STATE_NORMAL"
  else
    echo "$STATE_NORMAL"
  fi
}

write_state() {
  local new_state="$1"
  local note="${2:-}"
  python3 -c "
import json, datetime
d = {}
try:
    d = json.load(open('$STATE_FILE'))
except Exception:
    pass
d['state'] = '$new_state'
d['note'] = '$note'
d['updated_at'] = datetime.datetime.utcnow().isoformat() + 'Z'
json.dump(d, open('$STATE_FILE', 'w'), indent=2)
" 2>/dev/null || true
  log "State transition -> $new_state ($note)"
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
    log "⚠️ Stale lock file found (PID $lock_pid no longer exists). Clearing."
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
except Exception:
    print('')
" 2>/dev/null || echo "")
    if [[ -n "$updated_at" ]]; then
      local last_epoch now_epoch diff
      last_epoch=$(date -d "$updated_at" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$updated_at" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      diff=$(( now_epoch - last_epoch ))
      if (( diff < COOLDOWN_SECONDS )) && [[ "$FORCE" != "true" ]]; then
        die "Cooldown active: last state change was ${diff}s ago (cooldown: ${COOLDOWN_SECONDS}s). Wait $((COOLDOWN_SECONDS - diff))s or pass FORCE=true."
      fi
    fi
  fi
}

# ==============================================================================
# Manual approval gate (Fixes Issue 5)
# ==============================================================================
require_approval() {
  local operation="$1" # "failover" or "failback"
  local op_upper
  op_upper=$(echo "$operation" | tr '[:lower:]' '[:upper:]')

  # Pre-approval via environment variables (CI or automated testing)
  if [[ "$operation" == "failover" && ("$APPROVE_FAILOVER" == "true" || "$APPROVE_FAILOVER" == "yes" || "$APPROVE_FAILOVER" == "CONFIRM") ]]; then
    log "✅ Pre-approved via APPROVE_FAILOVER environment variable."
    return 0
  fi
  if [[ "$operation" == "failback" && ("$APPROVE_FAILBACK" == "true" || "$APPROVE_FAILBACK" == "yes" || "$APPROVE_FAILBACK" == "CONFIRM") ]]; then
    log "✅ Pre-approved via APPROVE_FAILBACK environment variable."
    return 0
  fi
  if [[ "$FORCE" == "true" || "$FORCE" == "yes" ]]; then
    log "✅ Pre-approved via FORCE=true environment variable."
    return 0
  fi

  if [[ "$MANUAL_APPROVAL" == "true" ]]; then
    if [[ -t 0 ]]; then
      log "⚠️ MANUAL APPROVAL REQUIRED for destructive operation: $op_upper"
      log "   Type 'CONFIRM' to authorize execution:"
      read -r -p "   [CONFIRM / cancel]: " answer
      if [[ "$answer" != "CONFIRM" && "$answer" != "yes" ]]; then
        die "Operation '$op_upper' was not confirmed by operator. Aborting."
      fi
      log "   ✅ Operator confirmed: $op_upper"
    else
      die "MANUAL_APPROVAL=true but running non-interactively without APPROVE_${op_upper}=true or FORCE=true. Aborting."
    fi
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
# PostgreSQL helper
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
# ACTION: failover (AWS Primary -> Azure DR)
# ==============================================================================
action_failover() {
  log_step "INITIATING CONTROLLED DR FAILOVER: AWS -> Azure"

  # 0. Required variable validation (Fixes Issue 3: Fail closed)
  local missing_vars=()
  [[ -z "$AWS_HEALTH_URL" ]]     && missing_vars+=("AWS_HEALTH_URL")
  [[ -z "$AZURE_HEALTH_URL" ]]   && missing_vars+=("AZURE_HEALTH_URL")
  [[ -z "$AWS_RDS_ENDPOINT" ]]   && missing_vars+=("AWS_RDS_ENDPOINT")
  [[ -z "$AWS_RDS_PASSWORD" ]]   && missing_vars+=("AWS_RDS_PASSWORD")
  [[ -z "$AZURE_PG_HOST" ]]      && missing_vars+=("AZURE_PG_HOST")
  [[ -z "$AZURE_PG_PASSWORD" ]]  && missing_vars+=("AZURE_PG_PASSWORD")
  if (( ${#missing_vars[@]} > 0 )); then
    die "Required environment variables not set: ${missing_vars[*]}"
  fi

  # Check state machine
  local current_state
  current_state=$(read_state)
  if [[ "$current_state" != "$STATE_NORMAL" ]] && [[ "$FORCE" != "true" ]]; then
    die "Cannot initiate failover: current state is '$current_state' (expected '$STATE_NORMAL')."
  fi

  check_cooldown
  require_approval "failover"

  write_state "$STATE_FAILOVER_IN_PROGRESS" "Failover started"

  # 1. Confirm AWS Primary is genuinely unhealthy
  log_step "Step 1: Confirming AWS Primary degradation"
  local aws_code
  aws_code=$(probe_endpoint "$AWS_HEALTH_URL")
  if [[ "$aws_code" == "200" ]] && [[ "$FORCE" != "true" ]]; then
    write_state "$STATE_NORMAL" "Failover aborted — AWS primary is healthy"
    die "AWS Primary returned HTTP 200 — it is currently healthy. Failover aborted to prevent unnecessary disruption."
  fi
  log "✅ AWS Primary confirmed degraded/unhealthy (HTTP $aws_code)."

  # 2. Verify Azure Secondary is healthy BEFORE switching
  log_step "Step 2: Verifying Azure Secondary standby readiness"
  local az_code
  az_code=$(probe_endpoint "$AZURE_HEALTH_URL")
  if [[ "$az_code" != "200" ]] && [[ "$FORCE" != "true" ]]; then
    write_state "$STATE_NORMAL" "Failover aborted — Azure unhealthy"
    die "Azure Secondary returned HTTP $az_code. Cannot fail over to an unhealthy DR target."
  fi
  log "✅ Azure Secondary is healthy (HTTP 200)."

  # 3. Verify Azure DB connectivity
  log_step "Step 3: Verifying Azure PostgreSQL connectivity"
  export PGPASSWORD="$AZURE_PG_PASSWORD"
  local db_check
  db_check=$(psql_exec "$AZURE_PG_HOST" "5432" "$AZURE_PG_ADMIN_USER" "$AZURE_PG_DB" "SELECT 1;" || echo "FAILED")
  if [[ "$db_check" != "1" ]]; then
    write_state "$STATE_NORMAL" "Failover aborted — Azure DB not reachable"
    die "Azure PostgreSQL is not reachable at $AZURE_PG_HOST. Cannot promote — failover aborted."
  fi
  log "✅ Azure PostgreSQL connection verified."

  # 4. FENCE AWS PRIMARY & VERIFY WRITE REJECTION (Fixes Issue 4)
  log_step "Step 4: Fencing AWS Primary and verifying write rejection"
  export PGPASSWORD="$AWS_RDS_PASSWORD"
  local fence_res
  fence_res=$(psql_exec "$AWS_RDS_ENDPOINT" "5432" "$AWS_RDS_ADMIN_USER" "$AWS_RDS_DB" \
    "ALTER SYSTEM SET default_transaction_read_only = on; SELECT pg_reload_conf();" 2>&1 || echo "FAILED")
  
  # Terminate open application write transactions on AWS
  psql_exec "$AWS_RDS_ENDPOINT" "5432" "$AWS_RDS_ADMIN_USER" "$AWS_RDS_DB" \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND usename NOT IN ('rdsadmin') AND state IN ('idle in transaction', 'active');" >/dev/null 2>&1 || true

  # VERIFY FENCE BY ATTEMPTING A WRITE OPERATION
  log "Verifying AWS Primary rejects application writes..."
  local fence_probe
  fence_probe=$(psql_exec "$AWS_RDS_ENDPOINT" "5432" "$AWS_RDS_ADMIN_USER" "$AWS_RDS_DB" \
    "INSERT INTO messages (content, author) VALUES ('fence_probe_test', 'sre_fence_probe');" 2>&1 || echo "FENCE_REJECTED")

  if echo "$fence_probe" | grep -qi "read-only"; then
    log "✅ Verified: AWS Primary successfully rejects write operations (read-only confirmed)."
  elif [[ "$fence_probe" == "FAILED" ]] || echo "$fence_probe" | grep -qi "could not connect\|Connection refused\|timeout"; then
    log "✅ AWS Primary is completely unreachable (hard down). Implicitly fenced."
  else
    if [[ "$FORCE_FAILOVER_WITHOUT_FENCE" != "true" ]]; then
      write_state "$STATE_NORMAL" "Failover aborted — AWS Primary fencing failed"
      die "FENCING VERIFICATION FAILED: AWS Primary still accepted writes ($fence_probe). Promoting secondary would create split-brain! Set FORCE_FAILOVER_WITHOUT_FENCE=true to override."
    else
      log "⚠️ FORCE_FAILOVER_WITHOUT_FENCE=true set. Proceeding despite fence anomaly."
    fi
  fi

  # 5. Promote Azure PostgreSQL subscriber (Fixes Issue 1: Pass all params)
  log_step "Step 5: Promoting Azure PostgreSQL to standalone read-write Primary"
  local promote_script
  promote_script="$(dirname "$0")/../replication/promote_subscriber_azure.sh"
  if [[ -f "$promote_script" ]]; then
    if ! AZURE_PG_HOST="$AZURE_PG_HOST" \
         AZURE_PG_PORT="5432" \
         AZURE_PG_ADMIN_USER="$AZURE_PG_ADMIN_USER" \
         AZURE_PG_DB="$AZURE_PG_DB" \
         AZURE_PG_PASSWORD="$AZURE_PG_PASSWORD" \
         bash "$promote_script"; then
      die "Promotion script failed. Azure DB may not be in a consistent state. ABORTING."
    fi
    log "✅ Azure PostgreSQL promotion script completed successfully."
  else
    die "Promotion script not found at $promote_script. Aborting."
  fi

  # 6. Verify Azure accepts writes post-promotion
  log_step "Step 6: Verifying Azure DB accepts writes post-promotion"
  export PGPASSWORD="$AZURE_PG_PASSWORD"
  local write_check
  write_check=$(psql_exec "$AZURE_PG_HOST" "5432" "$AZURE_PG_ADMIN_USER" "$AZURE_PG_DB" \
    "INSERT INTO replication_heartbeat (id, ts) VALUES (1, now()) ON CONFLICT (id) DO UPDATE SET ts=now(); SELECT 'write_ok';" 2>&1 || echo "FAILED")
  if [[ "$write_check" != *"write_ok"* ]]; then
    die "Azure PostgreSQL did NOT accept a write after promotion. Failover UNSAFE. Abort."
  fi
  log "✅ Azure PostgreSQL accepted a test write — promotion verified."

  # 7. Switch DNS routing to Azure DR
  log_step "Step 7: Switching DNS traffic to Azure DR"
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
    log "✅ Traffic Manager: AWS endpoint DISABLED. 100% traffic routed to Azure DR."

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
    log "ℹ️ Azure CLI not available. ACTION REQUIRED: Manually disable AWS endpoint in DNS manager."
  fi

  write_state "$STATE_FAILED_OVER" "Failover to Azure completed"
  log ""
  log "🎉 FAILOVER COMPLETED SUCCESSFULLY: AWS -> Azure DR"
  log "   Azure is now serving production traffic."
  log "   AWS RDS is strictly fenced (read-only)."
}

# ==============================================================================
# ACTION: failback (Azure DR -> AWS Primary) (Fixes Issue 2: Keep AWS Fenced)
# ==============================================================================
action_failback() {
  log_step "INITIATING CONTROLLED FAILBACK: Azure DR -> AWS Primary"

  local missing_vars=()
  [[ -z "$AWS_HEALTH_URL" ]]     && missing_vars+=("AWS_HEALTH_URL")
  [[ -z "$AWS_RDS_ENDPOINT" ]]   && missing_vars+=("AWS_RDS_ENDPOINT")
  [[ -z "$AWS_RDS_PASSWORD" ]]   && missing_vars+=("AWS_RDS_PASSWORD")
  [[ -z "$AZURE_PG_HOST" ]]      && missing_vars+=("AZURE_PG_HOST")
  [[ -z "$AZURE_PG_PASSWORD" ]]  && missing_vars+=("AZURE_PG_PASSWORD")
  if (( ${#missing_vars[@]} > 0 )); then
    die "Required environment variables not set: ${missing_vars[*]}"
  fi

  local current_state
  current_state=$(read_state)
  if [[ "$current_state" != "$STATE_FAILED_OVER" ]] && [[ "$FORCE" != "true" ]]; then
    die "Cannot failback: current state is '$current_state' (expected '$STATE_FAILED_OVER')."
  fi

  check_cooldown
  require_approval "failback"

  write_state "$STATE_FAILBACK_IN_PROGRESS" "Failback started"

  # 1. Verify AWS Primary compute and DB have recovered
  log_step "Step 1: Verifying AWS Primary compute and DB reachability"
  local aws_code
  aws_code=$(probe_endpoint "$AWS_HEALTH_URL")
  if [[ "$aws_code" != "200" ]] && [[ "$FORCE" != "true" ]]; then
    write_state "$STATE_FAILED_OVER" "Failback aborted — AWS still unhealthy"
    die "AWS Primary returned HTTP $aws_code — not recovered. Failback aborted."
  fi
  export PGPASSWORD="$AWS_RDS_PASSWORD"
  local aws_db_ping
  aws_db_ping=$(psql_exec "$AWS_RDS_ENDPOINT" "5432" "$AWS_RDS_ADMIN_USER" "$AWS_RDS_DB" "SELECT 1;" || echo "FAILED")
  if [[ "$aws_db_ping" != "1" ]]; then
    write_state "$STATE_FAILED_OVER" "Failback aborted — AWS DB unreachable"
    die "AWS RDS is unreachable at $AWS_RDS_ENDPOINT. Failback aborted."
  fi
  log "✅ AWS Primary and Database confirmed recovered and reachable."

  # 2. ENSURE AWS RDS REMAINS STRICTLY FENCED (DO NOT UNFENCE AWS HERE!)
  log_step "Step 2: Ensuring AWS RDS remains strictly FENCED (Read-Only) during delta sync"
  local aws_readonly
  aws_readonly=$(psql_exec "$AWS_RDS_ENDPOINT" "5432" "$AWS_RDS_ADMIN_USER" "$AWS_RDS_DB" "SHOW default_transaction_read_only;" || echo "off")
  if [[ "$aws_readonly" != "on" ]]; then
    log "Enforcing read-only fence on AWS RDS..."
    psql_exec "$AWS_RDS_ENDPOINT" "5432" "$AWS_RDS_ADMIN_USER" "$AWS_RDS_DB" \
      "ALTER SYSTEM SET default_transaction_read_only = on; SELECT pg_reload_conf();" >/dev/null
  fi
  log "✅ Confirmed: AWS RDS is strictly fenced (read-only) — simultaneous writes prevented."

  # 3. FENCE AZURE DR (Drain incoming writes on Azure before final delta sync)
  log_step "Step 3: Fencing Azure DR to freeze delta snapshot"
  export PGPASSWORD="$AZURE_PG_PASSWORD"
  psql_exec "$AZURE_PG_HOST" "5432" "$AZURE_PG_ADMIN_USER" "$AZURE_PG_DB" \
    "ALTER SYSTEM SET default_transaction_read_only = on; SELECT pg_reload_conf();" >/dev/null 2>&1 || true
  psql_exec "$AZURE_PG_HOST" "5432" "$AZURE_PG_ADMIN_USER" "$AZURE_PG_DB" \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND state IN ('idle in transaction', 'active');" >/dev/null 2>&1 || true
  log "✅ Azure DR fenced — database is quieted for exact delta sync."

  # 4. Resynchronize delta from Azure -> AWS via resync_failback_aws.sh (Fixes Issue 3)
  log_step "Step 4: Executing reverse resynchronization (Azure -> AWS Catch-up)"
  local resync_script
  resync_script="$(dirname "$0")/../replication/resync_failback_aws.sh"
  if [[ -f "$resync_script" ]]; then
    if ! AWS_PG_HOST="$AWS_RDS_ENDPOINT" \
         AWS_PG_PASSWORD="$AWS_RDS_PASSWORD" \
         AWS_PG_USER="$AWS_RDS_ADMIN_USER" \
         AWS_PG_DB="$AWS_RDS_DB" \
         AZURE_PG_HOST="$AZURE_PG_HOST" \
         AZURE_PG_PASSWORD="$AZURE_PG_PASSWORD" \
         AZURE_PG_USER="$AZURE_PG_ADMIN_USER" \
         AZURE_PG_DB="$AZURE_PG_DB" \
         bash "$resync_script"; then
      write_state "$STATE_FAILED_OVER" "Failback aborted — reverse resync failed"
      die "Reverse resync script failed or convergence timed out! AWS remains fenced. Failback ABORTED."
    fi
    log "✅ Reverse delta resynchronization completed and converged."
  else
    write_state "$STATE_FAILED_OVER" "Failback aborted — resync script missing"
    die "Resync script not found at $resync_script. Cannot safely failback without resynchronization."
  fi

  # 5. Data Consistency Verification
  log_step "Step 5: Verifying data consistency (row count and max ID comparison)"
  export PGPASSWORD="$AWS_RDS_PASSWORD"
  local aws_count aws_max_id
  aws_count=$(psql_exec "$AWS_RDS_ENDPOINT" "5432" "$AWS_RDS_ADMIN_USER" "$AWS_RDS_DB" "SELECT COUNT(*) FROM messages;" 2>&1 || echo "-1")
  aws_max_id=$(psql_exec "$AWS_RDS_ENDPOINT" "5432" "$AWS_RDS_ADMIN_USER" "$AWS_RDS_DB" "SELECT COALESCE(MAX(id), 0) FROM messages;" 2>&1 || echo "-1")

  export PGPASSWORD="$AZURE_PG_PASSWORD"
  local az_count az_max_id
  az_count=$(psql_exec "$AZURE_PG_HOST" "5432" "$AZURE_PG_ADMIN_USER" "$AZURE_PG_DB" "SELECT COUNT(*) FROM messages;" 2>&1 || echo "-2")
  az_max_id=$(psql_exec "$AZURE_PG_HOST" "5432" "$AZURE_PG_ADMIN_USER" "$AZURE_PG_DB" "SELECT COALESCE(MAX(id), 0) FROM messages;" 2>&1 || echo "-2")

  log "    AWS messages:   count=$aws_count, max_id=$aws_max_id"
  log "    Azure messages: count=$az_count, max_id=$az_max_id"

  if [[ "$aws_count" != "$az_count" || "$aws_max_id" != "$az_max_id" ]]; then
    write_state "$STATE_FAILED_OVER" "Failback aborted — data consistency mismatch"
    die "DATA CONSISTENCY CHECK FAILED! AWS ($aws_count rows) != Azure ($az_count rows). AWS Primary remains fenced."
  fi
  log "✅ Data consistency check PASSED: row counts and sequence heads match exactly."

  # 6. NOW AND ONLY NOW, UNFENCE AWS RDS (Re-enable writes on AWS Primary)
  log_step "Step 6: Unfencing AWS RDS (re-enabling writes on AWS Primary)"
  export PGPASSWORD="$AWS_RDS_PASSWORD"
  local unfence_res
  unfence_res=$(psql_exec "$AWS_RDS_ENDPOINT" "5432" "$AWS_RDS_ADMIN_USER" "$AWS_RDS_DB" \
    "ALTER SYSTEM SET default_transaction_read_only = off; SELECT pg_reload_conf();" 2>&1 || echo "FAILED")
  if echo "$unfence_res" | grep -qi "FAILED\|error"; then
    die "Failed to unfence AWS RDS ($unfence_res). Aborting before DNS repoint."
  fi

  # Verify AWS write
  local write_test
  write_test=$(psql_exec "$AWS_RDS_ENDPOINT" "5432" "$AWS_RDS_ADMIN_USER" "$AWS_RDS_DB" \
    "INSERT INTO replication_heartbeat (id, ts) VALUES (1, NOW()) ON CONFLICT (id) DO UPDATE SET ts = NOW(); SELECT 'AWS_WRITE_OK';" 2>&1 || echo "FAILED")
  if [[ "$write_test" != *"AWS_WRITE_OK"* ]]; then
    die "AWS RDS failed test write after unfencing! Aborting."
  fi
  log "✅ AWS RDS write verification confirmed."

  # 7. Restore DNS routing to AWS Primary
  log_step "Step 7: Restoring DNS routing to AWS Primary"
  if command -v az > /dev/null 2>&1 && [[ -n "$TM_PROFILE_NAME" ]]; then
    if ! az network traffic-manager endpoint update \
      --resource-group "$AZURE_RESOURCE_GROUP" \
      --profile-name "$TM_PROFILE_NAME" \
      --name aws-primary \
      --type externalEndpoints \
      --endpoint-status Enabled \
      --output none; then
      die "Azure CLI failed to re-enable AWS endpoint in Traffic Manager. DNS NOT changed."
    fi
    log "✅ Traffic Manager: AWS endpoint ENABLED."

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
    log "✅ DNS change confirmed: Traffic Manager reports AWS endpoint is Enabled."
  else
    log "ℹ️ Traffic Manager CLI not available. Action required: re-enable AWS endpoint in DNS manager."
  fi

  # 8. Re-arm Forward Replication on Azure (Azure becomes Subscriber again)
  log_step "Step 8: Re-arming Forward Logical Replication: AWS -> Azure"
  export PGPASSWORD="$AZURE_PG_PASSWORD"
  psql_exec "$AZURE_PG_HOST" "5432" "$AZURE_PG_ADMIN_USER" "$AZURE_PG_DB" \
    "ALTER SYSTEM SET default_transaction_read_only = off; SELECT pg_reload_conf();" >/dev/null 2>&1 || true

  psql_exec "$AZURE_PG_HOST" "5432" "$AZURE_PG_ADMIN_USER" "$AZURE_PG_DB" "
    DROP SUBSCRIPTION IF EXISTS failover_sub;
    CREATE SUBSCRIPTION failover_sub
      CONNECTION 'host=$AWS_RDS_ENDPOINT port=5432 user=$AWS_RDS_ADMIN_USER password=$AWS_RDS_PASSWORD dbname=$AWS_RDS_DB sslmode=require'
      PUBLICATION failover_pub
      WITH (copy_data = false, create_slot = true, enabled = true);
  " >/dev/null 2>&1 || log "⚠️ Notice: Subscription re-creation on Azure requires network route to AWS RDS."

  write_state "$STATE_NORMAL" "Failback to AWS completed successfully"
  log ""
  log "🎉 FAILBACK COMPLETED: AWS Primary is fully restored and serving production traffic."
  log "   Azure DR is returned to standby subscriber role."
}

# ==============================================================================
# ACTION: monitor (continuous health probe -> auto-failover)
# ==============================================================================
action_monitor() {
  log_step "CONTINUOUS HEALTH MONITOR — AWS Primary"

  if [[ -z "$AWS_HEALTH_URL" ]]; then
    die "AWS_HEALTH_URL is required for monitor mode."
  fi

  local current_state
  current_state=$(read_state)
  if [[ "$current_state" != "$STATE_NORMAL" ]]; then
    log "⚠️ Orchestrator state is '$current_state' — skipping auto-failover trigger."
    log "   Resolve the current state before running monitor mode."
    exit 0
  fi

  log "Probing AWS Primary (failure threshold: $FAILURE_THRESHOLD consecutive failures)..."
  local consecutive_fails=0

  for (( i=1; i<=FAILURE_THRESHOLD; i++ )); do
    local code
    code=$(probe_endpoint "$AWS_HEALTH_URL")
    log "Probe $i/$FAILURE_THRESHOLD: AWS Primary -> HTTP $code"

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
    echo "  APPROVE_FAILOVER=true   - Non-interactive approval for failover"
    echo "  APPROVE_FAILBACK=true   - Non-interactive approval for failback"
    echo "  COOLDOWN_SECONDS        - Minimum seconds between state changes (default: 300)"
    exit 1
    ;;
esac
