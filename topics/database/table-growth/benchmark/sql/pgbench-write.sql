\set id random(1, :rows)
UPDATE bench_orders
SET counter = counter + 1
WHERE id = :id;
