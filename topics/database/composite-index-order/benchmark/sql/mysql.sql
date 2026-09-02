SELECT CONCAT('Building events table with ', @rows, ' rows') AS experiment;

DROP TABLE IF EXISTS events, digits;
CREATE TABLE events (
    id bigint PRIMARY KEY,
    tenant_id int NOT NULL,
    status smallint NOT NULL,
    created_at datetime NOT NULL,
    payload varchar(40) NOT NULL
) ENGINE = InnoDB;

CREATE TABLE digits (n tinyint PRIMARY KEY);
INSERT INTO digits VALUES (0), (1), (2), (3), (4), (5), (6), (7), (8), (9);

INSERT INTO events
SELECT
    sequence.id,
    MOD(sequence.id, 1000),
    MOD(sequence.id * 37, 7),
    TIMESTAMPADD(SECOND, sequence.id, '2020-01-01 00:00:00'),
    REPEAT('x', 40)
FROM (
    SELECT
        ones.n + tens.n * 10 + hundreds.n * 100 + thousands.n * 1000
        + ten_thousands.n * 10000 + hundred_thousands.n * 100000 + 1 AS id
    FROM digits AS ones
    CROSS JOIN digits AS tens
    CROSS JOIN digits AS hundreds
    CROSS JOIN digits AS thousands
    CROSS JOIN digits AS ten_thousands
    CROSS JOIN digits AS hundred_thousands
) AS sequence
WHERE sequence.id <= @rows
ORDER BY sequence.id;

DROP TABLE digits;

ANALYZE TABLE events;

SELECT '1. Tenant-first index for one tenant timeline' AS experiment;
CREATE INDEX events_candidate_idx
ON events (tenant_id, created_at DESC, id DESC);
SELECT COUNT(*) FROM (
    SELECT id FROM events
    WHERE tenant_id = 500
    ORDER BY created_at DESC, id DESC
    LIMIT 50
) AS warmup;
EXPLAIN ANALYZE
SELECT id, created_at
FROM events
WHERE tenant_id = 500
ORDER BY created_at DESC, id DESC
LIMIT 50;
DROP INDEX events_candidate_idx ON events;

SELECT '2. Time-first index for the same tenant timeline' AS experiment;
CREATE INDEX events_candidate_idx
ON events (created_at DESC, id DESC, tenant_id);
SELECT COUNT(*) FROM (
    SELECT id FROM events
    WHERE tenant_id = 500
    ORDER BY created_at DESC, id DESC
    LIMIT 50
) AS warmup;
EXPLAIN ANALYZE
SELECT id, created_at
FROM events
WHERE tenant_id = 500
ORDER BY created_at DESC, id DESC
LIMIT 50;
DROP INDEX events_candidate_idx ON events;

SELECT '3. tenant_id before status when both are equality conditions' AS experiment;
CREATE INDEX events_candidate_idx
ON events (tenant_id, status, created_at DESC, id DESC);
SELECT COUNT(*) FROM (
    SELECT id FROM events
    WHERE tenant_id = 500 AND status = 6
    ORDER BY created_at DESC, id DESC
    LIMIT 10
) AS warmup;
EXPLAIN ANALYZE
SELECT id, created_at
FROM events
WHERE tenant_id = 500 AND status = 6
ORDER BY created_at DESC, id DESC
LIMIT 10;

SELECT '4. Tenant-only count with tenant_id first' AS experiment;
SELECT COUNT(*) FROM events WHERE tenant_id = 500;
EXPLAIN ANALYZE
SELECT COUNT(*) FROM events WHERE tenant_id = 500;
DROP INDEX events_candidate_idx ON events;

SELECT '5. status before tenant_id when both are equality conditions' AS experiment;
CREATE INDEX events_candidate_idx
ON events (status, tenant_id, created_at DESC, id DESC);
SELECT COUNT(*) FROM (
    SELECT id FROM events
    WHERE tenant_id = 500 AND status = 6
    ORDER BY created_at DESC, id DESC
    LIMIT 10
) AS warmup;
EXPLAIN ANALYZE
SELECT id, created_at
FROM events
WHERE tenant_id = 500 AND status = 6
ORDER BY created_at DESC, id DESC
LIMIT 10;

SELECT '6. Tenant-only count with status first and unconstrained' AS experiment;
SELECT COUNT(*) FROM events WHERE tenant_id = 500;
EXPLAIN ANALYZE
SELECT COUNT(*) FROM events WHERE tenant_id = 500;
DROP INDEX events_candidate_idx ON events;
