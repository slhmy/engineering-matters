\echo 'Building events table with' :rows 'rows'

DROP TABLE IF EXISTS events;
CREATE TABLE events (
    id bigint NOT NULL,
    match_bucket integer NOT NULL,
    account_id integer NOT NULL,
    created_at timestamp NOT NULL,
    status text NOT NULL,
    payload text NOT NULL
);

INSERT INTO events
SELECT
    id,
    (id * 7919) % 10000,
    (id * 3571) % 100000,
    timestamp '2024-01-01 00:00:00' + id * interval '1 second',
    CASE id % 4
        WHEN 0 THEN 'queued'
        WHEN 1 THEN 'running'
        WHEN 2 THEN 'complete'
        ELSE 'failed'
    END,
    repeat(md5(id::text), 5)
FROM generate_series(1, :rows::bigint) AS id;

-- This is intentionally the only index. It cannot cover the selected payload.
CREATE INDEX events_match_bucket_idx ON events (match_bucket);
-- Include every bucket in the statistics sample so estimates are reproducible.
ALTER TABLE events ALTER COLUMN match_bucket SET STATISTICS 10000;
VACUUM (ANALYZE) events;

\echo ''
\echo 'Table and index size'
SELECT
    pg_size_pretty(pg_relation_size('events')) AS heap_size,
    pg_size_pretty(pg_relation_size('events_match_bucket_idx')) AS index_size;

\echo ''
\echo '1. Predicate matches 0.01% (match_bucket < 1)'
\o /dev/null
SELECT id, account_id, created_at, status, payload FROM events WHERE match_bucket < 1;
\o
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, account_id, created_at, status, payload FROM events WHERE match_bucket < 1;

\echo ''
\echo '2. Predicate matches 0.1% (match_bucket < 10)'
\o /dev/null
SELECT id, account_id, created_at, status, payload FROM events WHERE match_bucket < 10;
\o
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, account_id, created_at, status, payload FROM events WHERE match_bucket < 10;

\echo ''
\echo '3. Predicate matches 1% (match_bucket < 100)'
\o /dev/null
SELECT id, account_id, created_at, status, payload FROM events WHERE match_bucket < 100;
\o
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, account_id, created_at, status, payload FROM events WHERE match_bucket < 100;

\echo ''
\echo '4. Predicate matches 10% (match_bucket < 1000)'
\o /dev/null
SELECT id, account_id, created_at, status, payload FROM events WHERE match_bucket < 1000;
\o
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, account_id, created_at, status, payload FROM events WHERE match_bucket < 1000;

\echo ''
\echo '5. Predicate matches 50% (match_bucket < 5000)'
\o /dev/null
SELECT id, account_id, created_at, status, payload FROM events WHERE match_bucket < 5000;
\o
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, account_id, created_at, status, payload FROM events WHERE match_bucket < 5000;

\echo ''
\echo '6. Predicate matches 90% (match_bucket < 9000)'
\o /dev/null
SELECT id, account_id, created_at, status, payload FROM events WHERE match_bucket < 9000;
\o
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, account_id, created_at, status, payload FROM events WHERE match_bucket < 9000;
