\echo 'Building events table with' :rows 'rows'

\set target_tenant 7

DROP TABLE IF EXISTS events;
CREATE TABLE events (
    id bigint PRIMARY KEY,
    tenant_id integer NOT NULL,
    created_at timestamp NOT NULL,
    payload text NOT NULL
);

INSERT INTO events
SELECT
    id,
    id % 10,
    timestamp '2020-01-01 00:00:00' + (id % 10000) * interval '1 second',
    repeat('x', 80)
FROM generate_series(1, :rows::bigint) AS id;

VACUUM (ANALYZE) events;

\echo ''
\echo '1. No matching index, LIMIT 50'
SELECT count(*) FROM (
    SELECT id, created_at
    FROM events
    WHERE tenant_id = :target_tenant
    ORDER BY created_at DESC, id DESC
    LIMIT 50
) AS warmup;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, created_at
FROM events
WHERE tenant_id = :target_tenant
ORDER BY created_at DESC, id DESC
LIMIT 50;

\echo ''
\echo '2. No matching index, large LIMIT (one tenth of all rows)'
SELECT count(*) FROM (
    SELECT id, created_at
    FROM events
    WHERE tenant_id = :target_tenant
    ORDER BY created_at DESC, id DESC
    LIMIT (:rows::bigint / 10)
) AS warmup;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, created_at
FROM events
WHERE tenant_id = :target_tenant
ORDER BY created_at DESC, id DESC
LIMIT (:rows::bigint / 10);

\echo ''
\echo 'Creating matching index (tenant_id, created_at DESC, id DESC)'
CREATE INDEX events_tenant_timeline_idx
ON events (tenant_id, created_at DESC, id DESC);
VACUUM (ANALYZE) events;

\echo ''
\echo '3. Matching index, LIMIT 50'
SELECT count(*) FROM (
    SELECT id, created_at
    FROM events
    WHERE tenant_id = :target_tenant
    ORDER BY created_at DESC, id DESC
    LIMIT 50
) AS warmup;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, created_at
FROM events
WHERE tenant_id = :target_tenant
ORDER BY created_at DESC, id DESC
LIMIT 50;

\echo ''
\echo '4. Matching index, large LIMIT (one tenth of all rows)'
SELECT count(*) FROM (
    SELECT id, created_at
    FROM events
    WHERE tenant_id = :target_tenant
    ORDER BY created_at DESC, id DESC
    LIMIT (:rows::bigint / 10)
) AS warmup;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, created_at
FROM events
WHERE tenant_id = :target_tenant
ORDER BY created_at DESC, id DESC
LIMIT (:rows::bigint / 10);
