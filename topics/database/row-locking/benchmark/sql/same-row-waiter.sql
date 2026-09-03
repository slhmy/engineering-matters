BEGIN;
SELECT clock_timestamp() AS wait_started \gset
UPDATE accounts SET balance = balance + 10 WHERE id = 1;
SELECT round(extract(epoch FROM (clock_timestamp() - :'wait_started'::timestamptz)) * 1000)::integer AS same_row_wait_ms;
COMMIT;
