\echo 'Building events table with' :rows 'rows'

\set target_tenant 500
\set target_status 6

DROP TABLE IF EXISTS events;
CREATE TABLE events (
    id bigint PRIMARY KEY,
    tenant_id integer NOT NULL,
    status smallint NOT NULL,
    created_at timestamp NOT NULL,
    payload text NOT NULL
);

INSERT INTO events
SELECT
    id,
    id % 1000,
    (id * 37) % 7,
    timestamp '2020-01-01 00:00:00' + id * interval '1 second',
    repeat('x', 40)
FROM generate_series(1, :rows::bigint) AS id;

VACUUM (ANALYZE) events;

\echo ''
\echo '1. Tenant-first index for one tenant timeline'
CREATE INDEX events_candidate_idx
ON events (tenant_id, created_at DESC, id DESC);
SELECT count(*) FROM (
    SELECT id FROM events
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
DROP INDEX events_candidate_idx;

\echo ''
\echo '2. Time-first index for the same tenant timeline'
CREATE INDEX events_candidate_idx
ON events (created_at DESC, id DESC, tenant_id);
SELECT count(*) FROM (
    SELECT id FROM events
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
DROP INDEX events_candidate_idx;

\echo ''
\echo '3. tenant_id before status when both are equality conditions'
CREATE INDEX events_candidate_idx
ON events (tenant_id, status, created_at DESC, id DESC);
SELECT count(*) FROM (
    SELECT id FROM events
    WHERE tenant_id = :target_tenant AND status = :target_status
    ORDER BY created_at DESC, id DESC
    LIMIT 10
) AS warmup;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, created_at
FROM events
WHERE tenant_id = :target_tenant AND status = :target_status
ORDER BY created_at DESC, id DESC
LIMIT 10;

\echo ''
\echo '4. Tenant-only count with tenant_id first'
SELECT count(*) FROM events WHERE tenant_id = :target_tenant;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM events WHERE tenant_id = :target_tenant;
DROP INDEX events_candidate_idx;

\echo ''
\echo '5. status before tenant_id when both are equality conditions'
CREATE INDEX events_candidate_idx
ON events (status, tenant_id, created_at DESC, id DESC);
SELECT count(*) FROM (
    SELECT id FROM events
    WHERE tenant_id = :target_tenant AND status = :target_status
    ORDER BY created_at DESC, id DESC
    LIMIT 10
) AS warmup;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, created_at
FROM events
WHERE tenant_id = :target_tenant AND status = :target_status
ORDER BY created_at DESC, id DESC
LIMIT 10;

\echo ''
\echo '6. Tenant-only count with status first and unconstrained'
SELECT count(*) FROM events WHERE tenant_id = :target_tenant;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM events WHERE tenant_id = :target_tenant;
DROP INDEX events_candidate_idx;
