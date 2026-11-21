-- ============================================================================
-- SCRIPT 03: Monitor Cross-Cloud PostgreSQL Logical Replication & Lag
-- ============================================================================

-- A. Run on Azure (Publisher) to check sender processes & subscriber byte lag
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

-- Check active replication slots on Publisher
SELECT 
  slot_name,
  plugin,
  slot_type,
  database,
  active,
  wal_status,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal_size
FROM pg_replication_slots;

-- B. Run on AWS RDS (Subscriber) to check worker status & sync state
SELECT 
  subid,
  subname,
  pid,
  relid,
  received_lsn,
  last_msg_send_time,
  last_msg_receipt_time,
  latest_end_lsn,
  latest_end_time
FROM pg_stat_subscription;

-- Check for sync errors on Subscriber
SELECT 
  subid,
  subname,
  apply_error_count,
  sync_error_count
FROM pg_stat_subscription_stats;
