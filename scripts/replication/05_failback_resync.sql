-- ============================================================================
-- SCRIPT 05: Failback Reverse Resynchronization (AWS -> Azure Catch-up)
-- Executed before switching DNS traffic back to Primary Azure
-- ============================================================================

-- Step A: Run on AWS RDS (Acts as Temporary Publisher of failover delta)
\c failoverdb;

-- 1. Create temporary publication on AWS for data written during the outage
DROP PUBLICATION IF EXISTS failback_pub;
CREATE PUBLICATION failback_pub FOR TABLE messages;

-- Step B: Run on Azure PostgreSQL (Acts as Catch-up Subscriber)
-- \c failoverdb;
-- CREATE SUBSCRIPTION failback_sub
--   CONNECTION 'host=failover-app-pg.xyz.ap-southeast-2.rds.amazonaws.com port=5432 user=pgadmin password=... dbname=failoverdb sslmode=require'
--   PUBLICATION failback_pub
--   WITH (copy_data = true, create_slot = true);

-- Step C: After Catch-up is verified (lag = 0), detach failback subscription on Azure
-- ALTER SUBSCRIPTION failback_sub DISABLE;
-- ALTER SUBSCRIPTION failback_sub SET (slot_name = NONE);
-- DROP SUBSCRIPTION failback_sub;

-- Step D: Advance Primary sequence on Azure to account for all newly synced records
-- SELECT setval(pg_get_serial_sequence('messages', 'id'), COALESCE((SELECT MAX(id) FROM messages), 1) + 1, false);

-- Step E: Re-enable standard Forward Publication on Azure
-- DROP PUBLICATION IF EXISTS failover_pub;
-- CREATE PUBLICATION failover_pub FOR TABLE messages;
