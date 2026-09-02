\echo 'Comparing primary-key shapes with' :rows 'rows'

SET work_mem = '256MB';

DROP TABLE IF EXISTS bigint_ids, ordered_uuid_ids, random_uuid_ids;
DROP TABLE IF EXISTS id_source;

-- Generate keys before measurement so UUID construction cost is not counted as
-- B-tree insertion cost. ordered_uuid is synthetic: it isolates key width and
-- insertion locality, but is not intended as an application ID format.
CREATE TABLE id_source AS
SELECT
    id AS source_id,
    id AS bigint_id,
    lpad(to_hex(id), 32, '0')::uuid AS ordered_uuid,
    md5('table-growth-' || id)::uuid AS random_uuid,
    repeat('x', 80) AS payload
FROM generate_series(1, :rows::bigint) AS id;
ANALYZE id_source;
SELECT count(*) FROM id_source;

CREATE TABLE bigint_ids (
    id bigint PRIMARY KEY,
    payload text NOT NULL
);
CREATE TABLE ordered_uuid_ids (
    id uuid PRIMARY KEY,
    payload text NOT NULL
);
CREATE TABLE random_uuid_ids (
    id uuid PRIMARY KEY,
    payload text NOT NULL
);

\echo ''
\echo '1. Incremental insert with sequential bigint keys'
EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF)
INSERT INTO bigint_ids
SELECT bigint_id, payload FROM id_source ORDER BY source_id;

\echo ''
\echo '2. Incremental insert with ordered UUID keys'
EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF)
INSERT INTO ordered_uuid_ids
SELECT ordered_uuid, payload FROM id_source ORDER BY source_id;

\echo ''
\echo '3. Incremental insert with random UUID keys'
EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF)
INSERT INTO random_uuid_ids
SELECT random_uuid, payload FROM id_source ORDER BY source_id;

VACUUM (ANALYZE) bigint_ids;
VACUUM (ANALYZE) ordered_uuid_ids;
VACUUM (ANALYZE) random_uuid_ids;

\echo ''
\echo '4. Table and primary-key index sizes'
SELECT
    relation,
    pg_size_pretty(pg_relation_size(relation::regclass)) AS table_size,
    pg_size_pretty(pg_indexes_size(relation::regclass)) AS index_size,
    pg_size_pretty(pg_total_relation_size(relation::regclass)) AS total_size
FROM unnest(ARRAY['bigint_ids', 'ordered_uuid_ids', 'random_uuid_ids']) AS relation;

SELECT
    bigint_id AS lookup_bigint,
    ordered_uuid AS lookup_ordered_uuid,
    random_uuid AS lookup_random_uuid
FROM id_source
WHERE source_id = :rows::bigint / 2
\gset

\echo ''
\echo '5. Warm point lookups'
SELECT count(*) FROM bigint_ids WHERE id = :lookup_bigint;
SELECT count(*) FROM ordered_uuid_ids WHERE id = :'lookup_ordered_uuid'::uuid;
SELECT count(*) FROM random_uuid_ids WHERE id = :'lookup_random_uuid'::uuid;

\echo ''
\echo '6. Point lookup with a bigint key'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT payload FROM bigint_ids WHERE id = :lookup_bigint;

\echo ''
\echo '7. Point lookup with an ordered UUID key'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT payload FROM ordered_uuid_ids WHERE id = :'lookup_ordered_uuid'::uuid;

\echo ''
\echo '8. Point lookup with a random UUID key'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT payload FROM random_uuid_ids WHERE id = :'lookup_random_uuid'::uuid;
