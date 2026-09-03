\set VERBOSITY verbose
BEGIN;
UPDATE accounts SET balance = balance + 10 WHERE id = 1;
