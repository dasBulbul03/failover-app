-- ============================================================================
-- SCRIPT 02: Setup PostgreSQL Logical Replication Subscriber on AWS
-- Secondary Cloud: Amazon Web Services (Amazon RDS for PostgreSQL 16)
-- ============================================================================

-- Prerequisites on AWS RDS DB Parameter Group:
--   1. rds.logical_replication = 1
--   2. max_replication_slots >= 5
--   3. max_logical_replication_workers >= 4

\c failoverdb;

BEGIN;

-- 1. Ensure Table Schema Exists Prior to Subscription Setup
-- (Logical replication replicates DML row changes, not DDL schema creation)
CREATE TABLE IF NOT EXISTS messages (
  id SERIAL PRIMARY KEY,
  content TEXT NOT NULL,
  author VARCHAR(100) NOT NULL DEFAULT 'Anonymous',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 2. Drop existing subscription if refreshing
DROP SUBSCRIPTION IF EXISTS failover_sub;

COMMIT;

-- 3. Create Subscription to Azure Publisher (Executed outside transaction block)
-- Replace credentials and hostname with your Azure PostgreSQL Flexible Server FQDN
CREATE SUBSCRIPTION failover_sub
  CONNECTION 'host=failover-app-pg-eastus.postgres.database.azure.com port=5432 user=repl_user password=CHANGE_ME_SECURE_REPL_PASSWORD dbname=failoverdb sslmode=require'
  PUBLICATION failover_pub
  WITH (
    copy_data = true,          -- Copies existing rows from Azure on initial sync
    create_slot = true,        -- Automatically creates replication slot on Azure
    enabled = true
  );

-- Verification
SELECT subid, subname, subenabled, subconninfo, subpublications
FROM pg_subscription
WHERE subname = 'failover_sub';

SELECT * FROM pg_stat_subscription;
