BEGIN;
SELECT id
FROM jobs
WHERE status = 'pending'
ORDER BY id
FOR UPDATE SKIP LOCKED
LIMIT 1
\gset

UPDATE jobs
SET status = 'running', claimed_by = :'worker'
WHERE id = :id;

SELECT :'worker' AS worker, :id::integer AS claimed_job;
