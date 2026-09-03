\pset format unaligned
\pset tuples_only on

BEGIN ISOLATION LEVEL :isolation;

SELECT 'RESULT|' || :'scenario' || '|first_balance=' || balance
FROM account
WHERE id = 1;

\o /dev/null
SELECT wait_for_barrier(:observed_barrier, 2);
SELECT wait_for_barrier(:committed_barrier, 2);
\o

SELECT 'RESULT|' || :'scenario' || '|second_balance=' || balance
FROM account
WHERE id = 1;

COMMIT;

\o /dev/null
SELECT pg_advisory_unlock_shared(4242, :observed_barrier);
SELECT pg_advisory_unlock_shared(4242, :committed_barrier);
\o
