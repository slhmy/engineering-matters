\echo 'Write path and index maintenance'
\echo 'Prefilled append table:' :rows 'rows; measured insert batch:' :batch 'rows'

DROP TABLE IF EXISTS insert_none;
DROP TABLE IF EXISTS insert_one;
DROP TABLE IF EXISTS insert_three;
DROP TABLE IF EXISTS append_one;
DROP TABLE IF EXISTS update_default;
DROP TABLE IF EXISTS update_fillfactor;

CREATE TABLE insert_none (
    id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    created_at timestamp NOT NULL,
    status text NOT NULL,
    payload text NOT NULL
);
CREATE TABLE insert_one (LIKE insert_none);
CREATE TABLE insert_three (LIKE insert_none);
CREATE TABLE append_one (LIKE insert_none);

CREATE INDEX insert_one_customer_idx ON insert_one (customer_id);

CREATE INDEX insert_three_customer_idx ON insert_three (customer_id);
CREATE INDEX insert_three_created_idx ON insert_three (created_at);
CREATE INDEX insert_three_status_idx ON insert_three (status);

CREATE INDEX append_one_customer_idx ON append_one (customer_id);

\echo ''
\echo '1. Insert the same batch into empty tables with 0, 1, and 3 secondary indexes'
EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF)
INSERT INTO insert_none (id, customer_id, created_at, status, payload)
SELECT g, (g * 7919) % 100000, timestamp '2020-01-01' + g * interval '1 second', 'new', repeat('x', 40)
FROM generate_series(1, :batch::bigint) AS g;

EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF)
INSERT INTO insert_one (id, customer_id, created_at, status, payload)
SELECT g, (g * 7919) % 100000, timestamp '2020-01-01' + g * interval '1 second', 'new', repeat('x', 40)
FROM generate_series(1, :batch::bigint) AS g;

EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF)
INSERT INTO insert_three (id, customer_id, created_at, status, payload)
SELECT g, (g * 7919) % 100000, timestamp '2020-01-01' + g * interval '1 second', 'new', repeat('x', 40)
FROM generate_series(1, :batch::bigint) AS g;

\echo ''
\echo '2. Prefill a larger append table and then insert the same batch'
INSERT INTO append_one (id, customer_id, created_at, status, payload)
SELECT g, (g * 7919) % 100000, timestamp '2020-01-01' + g * interval '1 second', 'old', repeat('x', 40)
FROM generate_series(1, :rows::bigint) AS g;
VACUUM (ANALYZE) append_one;

EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF)
INSERT INTO append_one (id, customer_id, created_at, status, payload)
SELECT g, (g * 7919) % 100000, timestamp '2020-01-01' + g * interval '1 second', 'new', repeat('x', 40)
FROM generate_series(:rows::bigint + 1, :rows::bigint + :batch::bigint) AS g;

\echo ''
\echo '3. Update cost on an indexed versus unindexed column'
CREATE TABLE update_default (
    id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    payload text NOT NULL
) WITH (fillfactor = 100);
CREATE TABLE update_fillfactor (
    id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    payload text NOT NULL
) WITH (fillfactor = 80);
CREATE INDEX update_default_customer_idx ON update_default (customer_id);
CREATE INDEX update_fillfactor_customer_idx ON update_fillfactor (customer_id);

INSERT INTO update_default (id, customer_id, payload)
SELECT g, (g * 7919) % 100000, repeat('x', 40) FROM generate_series(1, :batch::bigint) AS g;
INSERT INTO update_fillfactor (id, customer_id, payload)
SELECT g, (g * 7919) % 100000, repeat('x', 40) FROM generate_series(1, :batch::bigint) AS g;
VACUUM (ANALYZE) update_default, update_fillfactor;

SELECT pg_stat_reset();

\echo '3a. Unindexed column, fillfactor 100'
EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF)
UPDATE update_default SET payload = repeat('y', 40) WHERE id % 10 = 0;

\echo '3b. Unindexed column, fillfactor 80'
EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF)
UPDATE update_fillfactor SET payload = repeat('y', 40) WHERE id % 10 = 0;

\echo '3c. Indexed column, fillfactor 80'
EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF)
UPDATE update_fillfactor SET customer_id = customer_id + 1 WHERE id % 10 = 0;

\echo ''
\echo '4. Heap and index size after the inserts'
ANALYZE insert_none, insert_one, insert_three, append_one;
SELECT
    c.relname,
    c.reltuples::bigint AS estimated_rows,
    pg_relation_size(c.oid) AS heap_bytes,
    pg_indexes_size(c.oid) AS index_bytes,
    pg_total_relation_size(c.oid) AS total_bytes
FROM pg_class c
WHERE c.relname IN ('insert_none', 'insert_one', 'insert_three', 'append_one')
ORDER BY c.relname;


