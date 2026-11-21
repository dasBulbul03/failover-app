-- ============================================================================
-- SCRIPT 04: Promote Azure Subscriber to Standalone Read-Write Primary
-- Executed during Failover to Azure Secondary (when AWS Primary fails)
-- ============================================================================

\c failoverdb;

BEGIN;

-- 1. Ensure heartbeat table exists before promotion
CREATE TABLE IF NOT EXISTS replication_heartbeat (
  id INT PRIMARY KEY,
  ts TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMIT;

-- 2. Disable and drop the subscription to detach from AWS
-- (Must be executed outside of transaction block)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_subscription WHERE subname = 'failover_sub') THEN
    ALTER SUBSCRIPTION failover_sub DISABLE;
    ALTER SUBSCRIPTION failover_sub SET (slot_name = NONE);
    DROP SUBSCRIPTION failover_sub;
    RAISE NOTICE 'Successfully detached and dropped subscription failover_sub.';
  ELSE
    RAISE NOTICE 'Subscription failover_sub does not exist or already promoted.';
  END IF;
END
$$;

BEGIN;

-- 3. Synchronize Sequence Value for Primary Key Auto-Increment
SELECT setval(
  pg_get_serial_sequence('messages', 'id'),
  COALESCE((SELECT MAX(id) FROM messages), 0) + 1,
  false
);

-- 4. Record Promotion Event in Messages Table
INSERT INTO messages (content, author) 
VALUES ('System promoted to Primary on Azure Secondary Cloud (Disaster Recovery Mode)', 'SRE-Failover-Automation');

COMMIT;

-- 5. Output Verification Records
SELECT id, content, author, created_at 
FROM messages 
ORDER BY id DESC LIMIT 5;
