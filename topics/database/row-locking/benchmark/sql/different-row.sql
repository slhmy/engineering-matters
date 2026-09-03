BEGIN;
UPDATE accounts SET balance = balance + 20 WHERE id = 2;
SELECT id, balance AS different_row_balance FROM accounts WHERE id = 2;
COMMIT;
