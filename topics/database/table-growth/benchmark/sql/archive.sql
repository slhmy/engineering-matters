\echo 'Hot and cold archiving'
\echo 'Rows:' :rows

DROP TABLE IF EXISTS archive_full;
DROP TABLE IF EXISTS archive_full_partialindex;
DROP TABLE IF EXISTS archive_part CASCADE;

CREATE TABLE archive_full (
    id bigint PRIMARY KEY,
    created_at timestamp NOT NULL,
    customer_id bigint NOT NULL,
    payload text NOT NULL
);
CREATE TABLE archive_full_partialindex (LIKE archive_full INCLUDING ALL);

INSERT INTO archive_full (id, created_at, customer_id, payload)
SELECT
    g,
    timestamp '2020-01-01' + (g % 365) * interval '1 day',
    (g * 7919) % 10000,
    repeat('x', 40)
FROM generate_series(1, :rows::bigint) AS g;

INSERT INTO archive_full_partialindex
SELECT id, created_at, customer_id, payload FROM archive_full;

CREATE INDEX archive_full_created_idx ON archive_full (created_at, id);
CREATE INDEX archive_full_partial_created_idx
    ON archive_full_partialindex (created_at, id)
    WHERE created_at >= timestamp '2020-12-01';

CREATE TABLE archive_part (
    id bigint NOT NULL,
    created_at timestamp NOT NULL,
    customer_id bigint NOT NULL,
    payload text NOT NULL
) PARTITION BY RANGE (created_at);

CREATE TABLE archive_part_2020_01 PARTITION OF archive_part FOR VALUES FROM ('2020-01-01') TO ('2020-02-01');
CREATE TABLE archive_part_2020_02 PARTITION OF archive_part FOR VALUES FROM ('2020-02-01') TO ('2020-03-01');
CREATE TABLE archive_part_2020_03 PARTITION OF archive_part FOR VALUES FROM ('2020-03-01') TO ('2020-04-01');
CREATE TABLE archive_part_2020_04 PARTITION OF archive_part FOR VALUES FROM ('2020-04-01') TO ('2020-05-01');
CREATE TABLE archive_part_2020_05 PARTITION OF archive_part FOR VALUES FROM ('2020-05-01') TO ('2020-06-01');
CREATE TABLE archive_part_2020_06 PARTITION OF archive_part FOR VALUES FROM ('2020-06-01') TO ('2020-07-01');
CREATE TABLE archive_part_2020_07 PARTITION OF archive_part FOR VALUES FROM ('2020-07-01') TO ('2020-08-01');
CREATE TABLE archive_part_2020_08 PARTITION OF archive_part FOR VALUES FROM ('2020-08-01') TO ('2020-09-01');
CREATE TABLE archive_part_2020_09 PARTITION OF archive_part FOR VALUES FROM ('2020-09-01') TO ('2020-10-01');
CREATE TABLE archive_part_2020_10 PARTITION OF archive_part FOR VALUES FROM ('2020-10-01') TO ('2020-11-01');
CREATE TABLE archive_part_2020_11 PARTITION OF archive_part FOR VALUES FROM ('2020-11-01') TO ('2020-12-01');
CREATE TABLE archive_part_2020_12 PARTITION OF archive_part FOR VALUES FROM ('2020-12-01') TO ('2021-01-01');

CREATE INDEX archive_part_created_idx ON archive_part (created_at, id);

INSERT INTO archive_part (id, created_at, customer_id, payload)
SELECT
    g,
    timestamp '2020-01-01' + (g % 365) * interval '1 day',
    (g * 7919) % 10000,
    repeat('x', 40)
FROM generate_series(1, :rows::bigint) AS g;

VACUUM (ANALYZE) archive_full, archive_full_partialindex, archive_part;

\echo ''
\echo '1. Index storage for the hot slice (created_at >= 2020-12-01)'
SELECT 'full table, full index' AS variant, pg_relation_size('archive_full_created_idx') AS created_index_bytes
UNION ALL
SELECT 'full table, partial index', pg_relation_size('archive_full_partial_created_idx')
UNION ALL
SELECT 'partitioned table, local indexes', sum(pg_relation_size(ix.indexrelid))
FROM pg_inherits i
JOIN pg_index ix ON ix.indrelid = i.inhrelid
WHERE i.inhparent = 'archive_part'::regclass;

\echo ''
\echo '2. Hot row count and hot share'
SELECT
    count(*) FILTER (WHERE created_at >= timestamp '2020-12-01') AS hot_rows,
    count(*) AS total_rows,
    round(100.0 * count(*) FILTER (WHERE created_at >= timestamp '2020-12-01') / count(*), 2) AS hot_percent
FROM archive_full;

\echo ''
\echo '3. Recent-activity query against the full table'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, created_at
FROM archive_full
WHERE created_at >= timestamp '2020-12-01'
ORDER BY created_at, id
LIMIT 100;

\echo ''
\echo '4. Same query using the partial index'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, created_at
FROM archive_full_partialindex
WHERE created_at >= timestamp '2020-12-01'
ORDER BY created_at, id
LIMIT 100;

\echo ''
\echo '5. Same query against the partitioned table'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, created_at
FROM archive_part
WHERE created_at >= timestamp '2020-12-01'
ORDER BY created_at, id
LIMIT 100;

\echo ''
\echo '6. Cold query that must span every month'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*)
FROM archive_part
WHERE created_at >= timestamp '2020-01-01' AND created_at < timestamp '2020-07-01';
