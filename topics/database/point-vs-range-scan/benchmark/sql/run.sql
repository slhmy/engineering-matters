\echo 'Building records table with' :rows 'rows'

DROP TABLE IF EXISTS records;
CREATE TABLE records (
    id bigint PRIMARY KEY,
    payload text NOT NULL
);

INSERT INTO records (id, payload)
SELECT (physical_position * 7919) % :rows::bigint + 1, repeat('x', 64)
FROM generate_series(1, :rows::bigint) AS physical_position;

VACUUM (ANALYZE) records;

\echo ''
\echo 'Warming identical query shapes without printing their rows'
\o /dev/null
SELECT id, payload
FROM records
WHERE id = :rows::bigint / 4;

SELECT id, payload
FROM records
WHERE id >= :rows::bigint / 4
  AND id < :rows::bigint / 4 + 100;

SELECT id, payload
FROM records
WHERE id >= :rows::bigint / 4
  AND id < :rows::bigint / 4 + :rows::bigint / 100;

SELECT id, payload
FROM records
WHERE id >= :rows::bigint / 4
  AND id < :rows::bigint / 4 + :rows::bigint / 10;

SELECT id, payload
FROM records
WHERE id >= :rows::bigint / 4
  AND id < :rows::bigint / 4 + :rows::bigint / 2;
\o

\echo ''
\echo '1. One-row point lookup'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, payload
FROM records
WHERE id = :rows::bigint / 4;

\echo ''
\echo '2. Contiguous range: 100 rows'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, payload
FROM records
WHERE id >= :rows::bigint / 4
  AND id < :rows::bigint / 4 + 100;

\echo ''
\echo '3. Contiguous range: 1% of the table'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, payload
FROM records
WHERE id >= :rows::bigint / 4
  AND id < :rows::bigint / 4 + :rows::bigint / 100;

\echo ''
\echo '4. Contiguous range: 10% of the table'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, payload
FROM records
WHERE id >= :rows::bigint / 4
  AND id < :rows::bigint / 4 + :rows::bigint / 10;

\echo ''
\echo '5. Contiguous range: 50% of the table'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, payload
FROM records
WHERE id >= :rows::bigint / 4
  AND id < :rows::bigint / 4 + :rows::bigint / 2;
