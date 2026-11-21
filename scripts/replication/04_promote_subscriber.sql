-- ============================================================================
-- SCRIPT 04: Promote AWS Subscriber to Standalone Read-Write Primary
-- Executed during Failover to AWS Secondary
-- ============================================================================

\c failoverdb;

-- 1. Disable and drop the subscription to disconnect from Azure
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_subscription WHERE subname = 'failover_sub') THEN
    ALTER SUBSCRIPTION failover_sub DISABLE;
    ALTER SUBSCRIPTION failover_sub SET (slot_name = NONE);
    DROP SUBSCRIPTION failover_sub;
    RAISE NOTICE 'Successfully detached and dropped subscription failover_sub.';
  ELSE
    RAISE NOTICE 'Subscription failover_sub does not exist. Already promoted.';
  END IF;
END
$$;

-- 2. Synchronize Sequence Value
-- In logical replication, sequence values (auto-increment counters) are NOT replicated
-- automatically. We must advance the sequence to prevent duplicate key errors on INSERT!
SELECT setval(
  pg_get_serial_sequence('messages', 'id'),
  COALESCE((SELECT MAX(id) FROM messages), 1) + 1,
  false
);

-- 3. Verify Database is in Read-Write Mode
INSERT INTO messages (content, author) 
VALUES ('System promoted to Primary on AWS Secondary Cloud', 'SRE-Failover-Automation');

SELECT id, content, author, created_at 
FROM messages 
ORDER BY id DESC LIMIT 5;
