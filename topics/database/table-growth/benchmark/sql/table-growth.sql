\echo 'Building orders table with' :rows 'rows'

DROP TABLE IF EXISTS orders;
CREATE TABLE orders (
    id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    created_at timestamp NOT NULL,
    payload text NOT NULL
);

INSERT INTO orders (id, customer_id, created_at, payload)
SELECT
    id,
    (id * 7919) % GREATEST(:rows::bigint / 100, 1),
    timestamp '2020-01-01 00:00:00' + id * interval '1 second',
    repeat('x', 80)
FROM generate_series(1, :rows::bigint) AS id;

VACUUM (ANALYZE) orders;

\echo ''
\echo '1. Customer lookup without an index'
SELECT count(*) FROM orders WHERE customer_id = (:rows::bigint / 100) / 2;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, created_at, payload
FROM orders
WHERE customer_id = (:rows::bigint / 100) / 2;

\echo ''
\echo '2. Customer lookup with an index'
CREATE INDEX orders_customer_id_idx ON orders (customer_id);
ANALYZE orders;
SELECT count(*) FROM orders WHERE customer_id = (:rows::bigint / 100) / 2;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, created_at, payload
FROM orders
WHERE customer_id = (:rows::bigint / 100) / 2;

\echo ''
\echo '3. Deep pagination with OFFSET'
CREATE INDEX orders_created_at_id_idx ON orders (created_at, id);
ANALYZE orders;
SELECT count(*) FROM (
    SELECT id, created_at
    FROM orders
    ORDER BY created_at, id
    LIMIT 50 OFFSET GREATEST(:rows::bigint - 1000, 0)
) AS warmup;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, created_at
FROM orders
ORDER BY created_at, id
LIMIT 50 OFFSET GREATEST(:rows::bigint - 1000, 0);

\echo ''
\echo '4. Deep pagination with a cursor'
SELECT count(*) FROM (
    SELECT id, created_at
    FROM orders
    WHERE (created_at, id) > (
        timestamp '2020-01-01 00:00:00' + GREATEST(:rows::bigint - 1000, 0) * interval '1 second',
        GREATEST(:rows::bigint - 1000, 0)
    )
    ORDER BY created_at, id
    LIMIT 50
) AS warmup;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, created_at
FROM orders
WHERE (created_at, id) > (
    timestamp '2020-01-01 00:00:00' + GREATEST(:rows::bigint - 1000, 0) * interval '1 second',
    GREATEST(:rows::bigint - 1000, 0)
)
ORDER BY created_at, id
LIMIT 50;
