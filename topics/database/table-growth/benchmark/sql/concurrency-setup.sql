\echo 'Concurrency setup'
\echo 'Rows:' :rows

DROP TABLE IF EXISTS bench_orders;

CREATE TABLE bench_orders (
    id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    created_at timestamp NOT NULL,
    payload text NOT NULL,
    counter bigint NOT NULL DEFAULT 0
) WITH (fillfactor = 80);

INSERT INTO bench_orders (id, customer_id, created_at, payload)
SELECT g, (g * 7919) % 100000, timestamp '2020-01-01' + g * interval '1 second', repeat('x', 40)
FROM generate_series(1, :rows::bigint) AS g;

CREATE INDEX bench_orders_customer_idx ON bench_orders (customer_id);
VACUUM (ANALYZE) bench_orders;

SELECT pg_stat_reset();
