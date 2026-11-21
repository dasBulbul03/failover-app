-- ============================================================================
-- SCRIPT 02: Setup PostgreSQL Logical Replication Subscriber on Azure
-- Secondary Cloud: Microsoft Azure (Azure Database for PostgreSQL Flexible Server)
-- Publisher: Amazon Web Services (Amazon RDS for PostgreSQL 16)
-- ============================================================================

-- Prerequisites on Azure PostgreSQL Server Parameters:
--   1. azure.replication_support = logical
--   2. max_replication_slots >= 5
--   3. max_logical_replication_workers >= 4

\c failoverdb;

BEGIN;

-- 1. Ensure Table Schemas Exist Prior to Subscription Setup
CREATE TABLE IF NOT EXISTS messages (
  id SERIAL PRIMARY KEY,
  content TEXT NOT NULL,
  author VARCHAR(100) NOT NULL DEFAULT 'Anonymous',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS replication_heartbeat (
  id INT PRIMARY KEY,
  ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2. Drop existing subscription if refreshing
DROP SUBSCRIPTION IF EXISTS failover_sub;

COMMIT;

-- 3. Create Subscription to AWS Primary (Executed outside transaction block)
-- Replace credentials and hostname with your AWS RDS Endpoint FQDN
CREATE SUBSCRIPTION failover_sub
  CONNECTION 'host=failover-app-pg.xyz.ap-southeast-2.rds.amazonaws.com port=5432 user=repl_user password=CHANGE_ME_SECURE_REPL_PASSWORD dbname=failoverdb sslmode=require'
  PUBLICATION failover_pub
  WITH (
    copy_data = true,          -- Copies existing rows from AWS on initial sync
    create_slot = true,        -- Automatically creates replication slot on AWS
    enabled = true
  );

-- Verification Queries
SELECT subid, subname, subenabled, subconninfo, subpublications
FROM pg_subscription
WHERE subname = 'failover_sub';

SELECT * FROM pg_stat_subscription;
