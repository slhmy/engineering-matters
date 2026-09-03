\pset format unaligned
\pset tuples_only on
\set VERBOSITY verbose

BEGIN ISOLATION LEVEL :isolation;

SELECT count(*) AS observed_on_call
FROM doctors
WHERE on_call
\gset

SELECT 'RESULT|' || :'scenario' || '|' || :'doctor' || '_observed_on_call=' || :observed_on_call;

SELECT (:observed_on_call = 2) AS expected_count
\gset
\if :expected_count
\else
    \echo 'expected exactly two on-call doctors' >&2
    \quit 3
\endif

\o /dev/null
SELECT wait_for_barrier(:barrier, 2);
\o

UPDATE doctors
SET on_call = false
WHERE name = :'doctor';

COMMIT;

SELECT 'RESULT|' || :'scenario' || '|' || :'doctor' || '_commit=committed';

\o /dev/null
SELECT pg_advisory_unlock_shared(4242, :barrier);
\o
