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

### Expected Shape

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
