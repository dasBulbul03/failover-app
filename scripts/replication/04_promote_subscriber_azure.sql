-- ============================================================================
-- SCRIPT 04: Promote Azure Subscriber to Standalone Read-Write Primary
-- Executed during Failover to Azure Secondary (when AWS Primary fails)
-- ============================================================================

\c failoverdb;

-- 1. Disable and drop the subscription to detach from AWS
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
SELECT setval(
  pg_get_serial_sequence('messages', 'id'),
  COALESCE((SELECT MAX(id) FROM messages), 1) + 1,
  false
);

-- 3. Verify Database is in Read-Write Mode
INSERT INTO messages (content, author) 
VALUES ('System promoted to Primary on Azure Secondary Cloud (Disaster Recovery Mode)', 'SRE-Failover-Automation');

SELECT id, content, author, created_at 
FROM messages 
ORDER BY id DESC LIMIT 5;
