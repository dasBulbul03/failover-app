-- ============================================================================
-- SCRIPT 03: Monitor Cross-Cloud PostgreSQL Logical Replication & Lag
-- Architecture: AWS RDS (Primary / Publisher) -> Azure (Secondary DR / Subscriber)
-- ============================================================================

-- A. Run on AWS RDS (Publisher / Primary Cloud) to check WAL senders & slots
SELECT 
  pid,
  usename,
  client_addr,
  application_name,
  state,
  sync_state,
  sync_priority,
  pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn) AS sent_lag_bytes,
  pg_wal_lsn_diff(pg_current_wal_lsn(), write_lsn) AS write_lag_bytes,
  pg_wal_lsn_diff(pg_current_wal_lsn(), flush_lsn) AS flush_lag_bytes,
  pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag_bytes,
  write_lag,
  flush_lag,
  replay_lag
FROM pg_stat_replication;

-- Check active replication slots on AWS Publisher
SELECT 
  slot_name,
  plugin,
  slot_type,
  database,
  active,
  wal_status,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal_size,
  pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retained_wal_bytes
FROM pg_replication_slots;

-- B. Run on Azure PostgreSQL (Subscriber / Secondary DR Cloud) to check worker status & sync state
SELECT 
  subid,
  subname,
  pid,
  relid,
  received_lsn,
  last_msg_send_time,
  last_msg_receipt_time,
  EXTRACT(EPOCH FROM (NOW() - last_msg_receipt_time))::int AS seconds_since_last_msg,
  latest_end_lsn,
  latest_end_time
FROM pg_stat_subscription;

-- Check for sync errors on Azure Subscriber
SELECT 
  subid,
  subname,
  apply_error_count,
  sync_error_count
FROM pg_stat_subscription_stats;

-- C. Heartbeat Freshness Query (Run on Azure Subscriber)
-- Verifies true end-to-end data replication latency
SELECT
  id,
  ts AS last_heartbeat_timestamp,
  EXTRACT(EPOCH FROM (NOW() - ts))::int AS lag_seconds
FROM replication_heartbeat
WHERE id = 1;
