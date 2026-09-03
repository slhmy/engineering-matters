\set VERBOSITY verbose
BEGIN;
UPDATE accounts SET balance = balance + 100 WHERE id = 2;
