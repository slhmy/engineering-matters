\echo 'Building score table with' :rows 'rows'

DROP TABLE IF EXISTS ranked_scores, scores;
CREATE TABLE scores (
    id bigint PRIMARY KEY,
    score integer NOT NULL,
    payload text NOT NULL
);

-- There are at most 10,000 score values, so ties are common at larger sizes.
INSERT INTO scores
SELECT
    id,
    (id * 7919) % 10000,
    repeat('x', 40)
FROM generate_series(1, :rows::bigint) AS id;

CREATE INDEX scores_rank_idx ON scores (score DESC, id ASC);
VACUUM (ANALYZE) scores;

\echo ''
\echo '1. The 100th row ordered by score DESC, id ASC'
SELECT count(*) FROM (SELECT id FROM scores ORDER BY score DESC, id LIMIT 1 OFFSET 99) AS warmup;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, score FROM scores ORDER BY score DESC, id LIMIT 1 OFFSET 99;

\echo ''
\echo '2. The row at 10% of the table'
SELECT count(*) FROM (
    SELECT id FROM scores ORDER BY score DESC, id LIMIT 1 OFFSET (:rows::bigint / 10) - 1
) AS warmup;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, score
FROM scores
ORDER BY score DESC, id
LIMIT 1 OFFSET (:rows::bigint / 10) - 1;

\echo ''
\echo '3. The row at 90% of the table'
SELECT count(*) FROM (
    SELECT id FROM scores ORDER BY score DESC, id LIMIT 1 OFFSET (:rows::bigint * 9 / 10) - 1
) AS warmup;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, score
FROM scores
ORDER BY score DESC, id
LIMIT 1 OFFSET (:rows::bigint * 9 / 10) - 1;

\echo ''
\echo '4. The 1000th distinct score value'
SELECT count(*) FROM (
    SELECT DISTINCT score FROM scores ORDER BY score DESC LIMIT 1 OFFSET 999
) AS warmup;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT DISTINCT score FROM scores ORDER BY score DESC LIMIT 1 OFFSET 999;

\echo ''
\echo '5. Materialize every row rank for repeated random rank lookups'
EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF)
CREATE TABLE ranked_scores AS
SELECT
    row_number() OVER (ORDER BY score DESC, id ASC) AS rank,
    id,
    score
FROM scores;
ALTER TABLE ranked_scores ADD PRIMARY KEY (rank);
VACUUM (ANALYZE) ranked_scores;

\echo ''
\echo '6. Look up the precomputed 90% rank'
SELECT count(*) FROM ranked_scores WHERE rank = :rows::bigint * 9 / 10;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, score FROM ranked_scores WHERE rank = :rows::bigint * 9 / 10;

\echo ''
\echo '7. Cost of the materialized alternative'
SELECT
    pg_size_pretty(pg_relation_size('ranked_scores')) AS table_size,
    pg_size_pretty(pg_indexes_size('ranked_scores')) AS index_size,
    pg_size_pretty(pg_total_relation_size('ranked_scores')) AS total_size;
