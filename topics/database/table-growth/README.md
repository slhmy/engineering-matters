# Database table growth

This topic uses small experiments to understand which problems gradually appear as relational database tables grow.

## Problem Background

A business table may have only a few thousand rows early on, making queries, updates, and schema changes feel easy. As the table grows to millions or tens of millions of rows, problems that were previously invisible begin to appear.

For example:

- Queries without indexes become slow.
- Deep pagination gets slower.
- Aggregation queries consume more resources.
- DDL on large tables becomes risky.
- Backups, restores, and archival jobs take longer.
- Hot and cold data share the same table and affect common queries.

## Mental Model

A small table is like a thin notebook: scanning through it is still cheap.

A large table is more like an archive building. Without an index, finding one file means searching from beginning to end; with too many indexes, each new file requires maintaining many index cards.

## First Experiment: Query Cost As Rows Grow

The first runnable experiment is in [`benchmark/`](benchmark/). It runs a fixed PostgreSQL version with Docker Compose so the database engine and server configuration are explicit.

It compares:

- An equality lookup on `customer_id` without an index and with an index.
- A deep page using `LIMIT/OFFSET` and the same page using a `(created_at, id)` cursor.

The experiment varies row count (`100000` and `1000000`) while keeping the data shape and query shape fixed. It uses `EXPLAIN (ANALYZE, BUFFERS)` to record the chosen PostgreSQL plan, execution time, and visited buffers. See [`benchmark/README.md`](benchmark/README.md) for the exact command and assumptions.

One local run is recorded in [`result/2026-09-01-postgresql-17-darwin-arm64.md`](result/2026-09-01-postgresql-17-darwin-arm64.md). Run the benchmark on your own environment before using the numbers to make a capacity decision.

## Experiment And Result Interpretation

| Change | Observe | Interpretation |
| --- | --- | --- |
| Grow from 100,000 to 1,000,000 rows without a lookup index | Visited buffers grew from 1,725 to 17,242; PostgreSQL changed from `Seq Scan` to `Parallel Seq Scan`. | A missing access path makes work follow table size. Growth can change the plan shape, not only its duration. |
| Add `orders_customer_id_idx` | The one-million-row lookup visited about 100 matching heap blocks instead of scanning the table. | A selective index changes work from "inspect all rows" to "navigate to matching keys," at the cost of storage and write maintenance. |
| Move the requested page near the end | `OFFSET` produced 999,050 index entries to return 50 rows; the cursor produced 50 and visited 4 buffers. | An ordered index removes sorting, but `OFFSET` still walks and discards preceding entries. A cursor supplies a range boundary so the scan can start near the target. |

Read these as growth curves, not absolute latency claims. The principle is that query cost follows the amount of data the chosen access path must visit.

## Source And Pseudocode Walkthrough

The complete experiment is [`benchmark/sql/run.sql`](benchmark/sql/run.sql). The lookup query stays unchanged while the experiment adds one access path:

```sql
SELECT id, created_at, payload
FROM orders
WHERE customer_id = :customer_id;

CREATE INDEX orders_customer_id_idx ON orders (customer_id);
```

Before the index exists, PostgreSQL has no structure ordered by `customer_id`, so its practical algorithm is `for each row: test customer_id`. After the index exists, it can descend the B-tree to `:customer_id`, read the matching index entries, and fetch only their heap rows. The SQL result is the same; the amount of visited data changes.

The pagination cases use the same `(created_at, id)` order but encode the starting position differently:

```sql
-- Walk from the beginning and discard preceding entries.
SELECT id, created_at
FROM orders
ORDER BY created_at, id
LIMIT 50 OFFSET :position;

-- Seek to a known boundary and continue from there.
SELECT id, created_at
FROM orders
WHERE (created_at, id) > (:cursor_time, :cursor_id)
ORDER BY created_at, id
LIMIT 50;
```

The tuple comparison is lexicographic: compare `created_at` first, then use `id` to break ties. It matches the index column order, so the cursor path is approximately `B-tree seek + 50 next entries`; the offset path is `first entry + position skips + 50 next entries`. Removing `id` would make equal timestamps ambiguous and could cause skipped or repeated rows between pages.

## Detailed Explanation

Without an index, the lookup has to inspect the table until it finds qualifying rows. An index changes that work into an index traversal plus row lookups, which is usually a better trade when the predicate is selective enough. The index is not free: it consumes space and must be maintained by writes.

For a deep page, `OFFSET` expresses "walk in order, discard N rows, then return the next page." A cursor expresses "start after this known key." The latter avoids repeating the discard work as the position moves deeper, but it requires a stable, ordered cursor and does not naturally support jumping to an arbitrary page number.

These are tendencies, not guarantees. Selectivity, cache state, row width, indexes, query plan choices, and the database engine all affect the result.

## Focus

This topic is not only about "optimizing SQL"; it is about understanding how engineering maintenance costs change as data grows.

## Next Additions

- Measure write throughput and database size with zero, one, and several secondary indexes.
- Compare narrow rows with wide payloads and covering indexes.
- Add archival or hot/cold data experiments.
- Add concurrent readers and writers to expose cache, I/O, and lock effects.
