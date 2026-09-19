\echo 'Row width and TOAST'
\echo 'Rows per table:' :rows

DROP TABLE IF EXISTS width_narrow;
DROP TABLE IF EXISTS width_wide;

CREATE TABLE width_narrow (
    id bigint PRIMARY KEY,
    bucket int NOT NULL,
    created_at timestamp NOT NULL,
    payload text NOT NULL
);
CREATE TABLE width_wide (
    id bigint PRIMARY KEY,
    bucket int NOT NULL,
    created_at timestamp NOT NULL,
    payload text NOT NULL
);

ALTER TABLE width_wide ALTER COLUMN payload SET STORAGE EXTERNAL;

CREATE INDEX width_narrow_bucket_idx ON width_narrow (bucket);
CREATE INDEX width_wide_bucket_idx ON width_wide (bucket);

INSERT INTO width_narrow (id, bucket, created_at, payload)
SELECT g, (g * 7919) % 10000, timestamp '2020-01-01' + g * interval '1 second', repeat('n', 40)
FROM generate_series(1, :rows::bigint) AS g;

INSERT INTO width_wide (id, bucket, created_at, payload)
SELECT g, (g * 7919) % 10000, timestamp '2020-01-01' + g * interval '1 second', repeat(md5(g::text), 200)
FROM generate_series(1, :rows::bigint) AS g;

VACUUM (ANALYZE) width_narrow, width_wide;

\echo ''
\echo '1. Storage size, including out-of-line TOAST'
SELECT
    c.relname,
    pg_relation_size(c.oid) AS heap_bytes,
    pg_indexes_size(c.oid) AS index_bytes,
    pg_total_relation_size(c.oid) - pg_relation_size(c.oid) - pg_indexes_size(c.oid) AS toast_bytes,
    pg_total_relation_size(c.oid) AS total_bytes
FROM pg_class c
WHERE c.relname IN ('width_narrow', 'width_wide')
ORDER BY c.relname;

\echo ''
\echo '2. Narrow projection: both tables return columns stored on the main heap'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, created_at
FROM width_narrow
WHERE bucket BETWEEN 500 AND 600;

EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, created_at
FROM width_wide
WHERE bucket BETWEEN 500 AND 600;

\echo ''
\echo '3. Touching the payload forces TOAST reads on the wide table'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, length(payload)
FROM width_narrow
WHERE bucket BETWEEN 500 AND 600;

EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, length(payload)
FROM width_wide
WHERE bucket BETWEEN 500 AND 600;

\echo ''
\echo '4. Full-table aggregate over the payload'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*), sum(length(payload))
FROM width_narrow;

EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*), sum(length(payload))
FROM width_wide;
