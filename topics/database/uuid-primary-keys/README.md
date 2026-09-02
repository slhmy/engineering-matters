# UUID primary keys

Choosing UUID instead of `bigint` changes more than the textual shape of an ID. This experiment separates two pressures that are often mixed together:

- Key width: PostgreSQL stores native `uuid` in 16 bytes and `bigint` in 8 bytes.
- Insertion locality: increasing keys usually reach the right edge of a B-tree, while random UUIDs insert across many leaf pages.

## Cases

| Table | Key | Input order | Question |
| --- | --- | --- | --- |
| `bigint_ids` | Increasing `bigint` | Increasing | Small, ordered baseline |
| `ordered_uuid_ids` | Synthetic increasing `uuid` | Increasing | What changes when the key is wider but remains ordered? |
| `random_uuid_ids` | Deterministic MD5-derived `uuid` | Random key order | What additional cost appears when inserts lose locality? |

The ordered UUID is deliberately synthetic. It is a control variable, not an ID-generation recommendation or an implementation of UUIDv7. The random UUIDs are generated before measurement so hashing does not count as insertion work.

## Experiment

The runnable PostgreSQL experiment is in [`benchmark/`](benchmark/). Run it from that directory:

```bash
cd topics/database/uuid-primary-keys/benchmark
./run.sh 100000
./run.sh 1000000
```

Remove the temporary database after the run with `docker compose down`.

Inspect:

- `Buffers` and `WAL` for each `INSERT`; treat one run's execution time as secondary evidence.
- Primary-key index and total relation size.
- B-tree depth as indirectly reflected by buffers visited during point lookup.

One local run is recorded in [`result/2026-09-01-postgresql-17-darwin-arm64.md`](result/2026-09-01-postgresql-17-darwin-arm64.md).

## Experiment And Result Interpretation

| Change | Observe | Interpretation |
| --- | --- | --- |
| Replace sequential `bigint` with an ordered synthetic UUID | At one million rows, the table grew from 120 MB to 128 MB and the primary-key index from 21 MB to 30 MB. | Even with the same insertion locality, a 16-byte UUID makes table tuples and B-tree entries wider than an 8-byte `bigint`. |
| Randomize UUID insertion order | The UUID primary-key index grew from 30 MB to 38 MB and generated more WAL in this run. | Inserts spread across B-tree leaves instead of concentrating on the right edge, increasing page maintenance and reducing packing efficiency. |
| Perform a warm point lookup | All three primary keys visited about 4 buffers. | Hot point-query latency can look similar while indexes have comparable height; it does not reveal storage, WAL, or sustained-write costs. |

Use relation size and WAL as the primary signals in this experiment. One fixed-order bulk insert time is too sensitive to cache and checkpoint timing to rank identifier strategies.

## Source And Pseudocode Walkthrough

The complete experiment is [`benchmark/sql/run.sql`](benchmark/sql/run.sql). It generates all key forms before measuring insertion:

```sql
SELECT
    id AS source_id,
    id AS bigint_id,
    lpad(to_hex(id), 32, '0')::uuid AS ordered_uuid,
    md5('table-growth-' || id)::uuid AS random_uuid
FROM generate_series(1, :rows::bigint) AS id;
```

`ordered_uuid` preserves the numeric order of `id`; it isolates the cost of changing an 8-byte key into a 16-byte key. `random_uuid` deterministically scrambles the same source IDs, giving repeatable random B-tree positions. Pre-generating both values keeps UUID construction and hashing outside the measured insert.

All targets then receive rows in the same `source_id` order:

```sql
EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF)
INSERT INTO ordered_uuid_ids
SELECT ordered_uuid, payload FROM id_source ORDER BY source_id;

EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF)
INSERT INTO random_uuid_ids
SELECT random_uuid, payload FROM id_source ORDER BY source_id;
```

The first insert repeatedly reaches the right side of the UUID B-tree because key order follows arrival order. The second receives the same arrivals but routes each key to a different leaf according to its UUID value. `BUFFERS` reveals page activity, `WAL` reveals logged write volume, and `pg_indexes_size` captures the final packing outcome. This control is why a difference can be attributed mainly to insertion locality rather than ID-generation CPU time.

## Detailed Explanation

The ordered UUID index should generally be larger than the `bigint` index because every key and internal separator is wider. The random UUID index may be larger again because incremental random insertion tends to leave pages less densely packed and causes more page splits.

Point lookup can remain similarly fast while all indexes fit in memory and have similar height. This is why a small point-query benchmark can miss UUID's storage, cache, WAL, and write-locality costs. Differences become more important when the index stops fitting comfortably in memory or writes are sustained and concurrent.

Time-ordered identifiers such as UUIDv7 can improve insertion locality while retaining decentralized generation, but they remain wider than `bigint` and expose approximate creation time. Their behavior also depends on generation quality and ordering among IDs created in the same time interval.

## Boundaries

- Use PostgreSQL's native `uuid`, not a 36-character text column, when the domain is UUID.
- Random UUIDs can be useful when IDs must be generated independently across systems. That operational property may outweigh index cost.
- Sequential IDs are not an authorization mechanism. Guessability and access control are separate concerns.
- Bulk index construction can pack random values differently from continuous random inserts. This experiment intentionally measures incremental primary-key maintenance.
- One bulk insert does not reproduce long-running bloat, cache eviction, checkpoints, replicas, or concurrent page contention.
- Fixed execution order can affect cache and checkpoint timing. Compare WAL and relation size before treating a small elapsed-time difference as meaningful.
