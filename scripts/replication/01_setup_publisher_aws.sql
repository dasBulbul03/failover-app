-- ============================================================================
-- SCRIPT 01: Setup PostgreSQL Logical Replication Publisher on AWS
-- Primary Cloud: Amazon Web Services (Amazon RDS for PostgreSQL 16)
-- Target Subscriber: Microsoft Azure (Azure Database for PostgreSQL Flexible Server)
-- ============================================================================

-- Prerequisites on AWS RDS DB Parameter Group:
--   1. rds.logical_replication = 1
--   2. max_wal_senders >= 10
--   3. max_replication_slots >= 10

\c failoverdb;

BEGIN;

-- 1. Create dedicated replication user with minimal required privileges
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'repl_user') THEN
    CREATE ROLE repl_user WITH REPLICATION LOGIN PASSWORD 'CHANGE_ME_SECURE_REPL_PASSWORD';
  END IF;
END
$$;

-- 2. Create replication heartbeat table for true logical replication freshness monitoring
CREATE TABLE IF NOT EXISTS replication_heartbeat (
  id INT PRIMARY KEY,
  ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
INSERT INTO replication_heartbeat (id, ts) VALUES (1, NOW())
ON CONFLICT (id) DO UPDATE SET ts = NOW();

-- 3. Grant permissions to the replication user
GRANT CONNECT ON DATABASE failoverdb TO repl_user;
GRANT USAGE ON SCHEMA public TO repl_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO repl_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO repl_user;

-- 4. Configure Replica Identity for data change capture
-- DEFAULT uses the primary key for identifying rows in UPDATE/DELETE
ALTER TABLE messages REPLICA IDENTITY DEFAULT;
ALTER TABLE replication_heartbeat REPLICA IDENTITY DEFAULT;

-- 5. Create Publication for the application tables and heartbeat
DROP PUBLICATION IF EXISTS failover_pub;
CREATE PUBLICATION failover_pub FOR TABLE messages, replication_heartbeat;

COMMIT;

-- Verification Queries
SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete, pubtruncate 
FROM pg_publication WHERE pubname = 'failover_pub';

SELECT slot_name, plugin, slot_type, active 
FROM pg_replication_slots;
