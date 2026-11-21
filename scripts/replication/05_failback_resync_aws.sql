-- ============================================================================
-- SCRIPT 05: Failback Reverse Resynchronization (Azure -> AWS Catch-up)
-- Executed before switching DNS traffic back to Primary AWS
-- ============================================================================

-- Step A: Run on Azure PostgreSQL (Acts as Temporary Publisher of failover delta)
\c failoverdb;

-- 1. Create temporary publication on Azure for data written during the outage
DROP PUBLICATION IF EXISTS failback_pub;
CREATE PUBLICATION failback_pub FOR TABLE messages;

-- Step B: Run on AWS RDS (Acts as Catch-up Subscriber)
-- \c failoverdb;
-- CREATE SUBSCRIPTION failback_sub
--   CONNECTION 'host=failover-app-pg.postgres.database.azure.com port=5432 user=pgadmin password=... dbname=failoverdb sslmode=require'
--   PUBLICATION failback_pub
--   WITH (copy_data = true, create_slot = true);

-- Step C: After Catch-up is verified (lag = 0), detach failback subscription on AWS
-- ALTER SUBSCRIPTION failback_sub DISABLE;
-- ALTER SUBSCRIPTION failback_sub SET (slot_name = NONE);
-- DROP SUBSCRIPTION failback_sub;

-- Step D: Advance Primary sequence on AWS to account for all newly synced records
-- SELECT setval(pg_get_serial_sequence('messages', 'id'), COALESCE((SELECT MAX(id) FROM messages), 1) + 1, false);

-- Step E: Re-enable standard Forward Publication on AWS
-- DROP PUBLICATION IF EXISTS failover_pub;
-- CREATE PUBLICATION failover_pub FOR TABLE messages;
