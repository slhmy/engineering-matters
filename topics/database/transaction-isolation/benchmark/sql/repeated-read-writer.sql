BEGIN;

\o /dev/null
SELECT wait_for_barrier(:observed_barrier, 2);
\o

UPDATE account
SET balance = 120
WHERE id = 1;

COMMIT;

\o /dev/null
SELECT wait_for_barrier(:committed_barrier, 2);
SELECT pg_advisory_unlock_shared(4242, :observed_barrier);
SELECT pg_advisory_unlock_shared(4242, :committed_barrier);
\o
