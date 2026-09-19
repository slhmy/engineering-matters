\set id random(1, :rows)
SELECT id, customer_id, created_at, payload
FROM bench_orders
WHERE id = :id;
