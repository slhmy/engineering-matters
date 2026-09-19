# Database table growth

This topic uses small experiments to understand which problems gradually appear as relational database tables grow.

A growing table does not only make queries slower. It raises write cost, increases storage and WAL, changes cache residency, and makes maintenance decisions (indexes, archiving, vacuum) more expensive. The experiments below separate those pressures so each one stays visible.

The read-only query experiments are recorded in [`result/2026-09-01-postgresql-17-darwin-arm64.md`](result/2026-09-01-postgresql-17-darwin-arm64.md). The write, row-width, archiving, and concurrency experiments are recorded in [`result/2026-09-19-postgresql-17-darwin-arm64.md`](result/2026-09-19-postgresql-17-darwin-arm64.md).

## Problem Background

A business table may have only a few thousand rows early on, making queries, updates, and schema changes feel easy. As the table grows to millions or tens of millions of rows, problems that were previously invisible begin to appear.

For example:

- Queries without indexes become slow.
- Deep pagination gets slower.
- Aggregation queries consume more resources.
- Every insert and update maintains every index.
- Wide rows move to TOAST and multiply I/O.
- DDL on large tables becomes risky.
- Backups, restores, and archival jobs take longer.
- Hot and cold data share the same table and affect common queries.

## Mental Model

A small table is like a thin notebook: scanning through it is still cheap.

A large table is more like an archive building. Without an index, finding one file means searching from beginning to end; with too many indexes, each new file requires maintaining many index cards; with wide rows, the shelves themselves consume more space.

## Experiment 1: Query Cost As Rows Grow

The first runnable experiment is in [`benchmark/`](benchmark/). It runs a fixed PostgreSQL version with Docker Compose so the database engine and server configuration are explicit.

It compares:

- An equality lookup on `customer_id` without an index and with an index.
- A deep page using `LIMIT/OFFSET` and the same page using a `(created_at, id)` cursor.

The experiment varies row count (`100000` and `1000000`) while keeping the data shape and query shape fixed. It uses `EXPLAIN (ANALYZE, BUFFERS)` to record the chosen PostgreSQL plan, execution time, and visited buffers. See [`benchmark/README.md`](benchmark/README.md) for the exact command and assumptions.

Run it with:

```bash
cd topics/database/table-growth/benchmark
./run.sh 100000
./run.sh 1000000
docker compose down
```

One local run is recorded in [`result/2026-09-01-postgresql-17-darwin-arm64.md`](result/2026-09-01-postgresql-17-darwin-arm64.md). Run the benchmark on your own environment before using the numbers to make a capacity decision.

### Query Result Interpretation

| Change | Observe | Interpretation |
| --- | --- | --- |
| Grow from 100,000 to 1,000,000 rows without a lookup index | Visited buffers grew from 1,725 to 17,242; PostgreSQL changed from `Seq Scan` to `Parallel Seq Scan`. | A missing access path makes work follow table size. Growth can change the plan shape, not only its duration. |
| Add `orders_customer_id_idx` | The one-million-row lookup visited about 100 matching heap blocks instead of scanning the table. | A selective index changes work from "inspect all rows" to "navigate to matching keys," at the cost of storage and write maintenance. |
| Move the requested page near the end | `OFFSET` produced 999,050 index entries to return 50 rows; the cursor produced 50 and visited 4 buffers. | An ordered index removes sorting, but `OFFSET` still walks and discards preceding entries. A cursor supplies a range boundary so the scan can start near the target. |

Read these as growth curves, not absolute latency claims. The principle is that query cost follows the amount of data the chosen access path must visit.

### Query Source And Pseudocode Walkthrough

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

## Experiment 2: Write Path And Index Maintenance

Queries are only half of table growth. Every insert maintains the primary key plus each secondary index, and every update may rewrite index entries unless it can be heap-only.

The runnable experiment is [`benchmark/sql/writes.sql`](benchmark/sql/writes.sql), run with:

```bash
cd topics/database/table-growth/benchmark
./run-writes.sh 1000000 100000
docker compose down
```

It inserts the same 100,000-row batch into empty tables with 0, 1, and 3 secondary indexes, appends the same batch to a table already holding 1,000,000 rows, and updates 10,000 rows on tables with different fillfactor and indexed-column choices.

### Write Result Interpretation

| Change | Observe in the local run | Interpretation |
| --- | --- | --- |
| Add secondary indexes to one insert batch | 100,000 inserts took 88.452 ms with 0 secondary indexes, 105.049 ms with 1, and 194.471 ms with 3; WAL rose from 19.0 MB to 19.8 MB to 32.9 MB. | Each index adds an index insert and its WAL to every row, so write cost follows the index portfolio. |
| Append the same batch to 1,100,000 rows | Time rose from 105.049 ms to 127.866 ms and WAL from 19.8 MB to 21.1 MB. | A deeper B-tree and larger heap add page visits per row; per-row write cost grows slowly with table size. |
| Update an unindexed column | At fillfactor 100 the update wrote 3.13 MB of WAL and made 0 heap-only updates; at fillfactor 80 it wrote 1.08 MB and made 10,000 of 10,000 heap-only updates. | A non-indexed update avoids index maintenance only when the new tuple fits on the same page. |
| Update an indexed column | Even with fillfactor 80, the indexed update wrote 2.11 MB of WAL and no heap-only updates. | Changing an indexed value always writes new index entries. |

The final one-index table added about 156 kB of index storage over the primary key alone; the three-index table added about 3.1 MB. The 1.1-million-row table reached 111 MB of heap and 12.9 MB of indexes.

## Experiment 3: Row Width And TOAST

Payload width decides whether values stay on the main heap page or move to out-of-line TOAST storage. A query that never touches the wide column pays little; a query that does pays in extra page reads.

The runnable experiment is [`benchmark/sql/toast.sql`](benchmark/sql/toast.sql), run with:

```bash
cd topics/database/table-growth/benchmark
./run-toast.sh 50000
docker compose down
```

It builds a 40-byte narrow table and a roughly 6,400-byte wide table with `STORAGE EXTERNAL`, both holding 50,000 rows, then compares storage and buffered plans.

### Row Width Result Interpretation

| Change | Observe in the local run | Interpretation |
| --- | --- | --- |
| Widen the payload from 40 B to about 6.4 kB | Total storage grew from 6.9 MB to 419.9 MB, while the main heap shrank slightly from 5.06 MB to 3.83 MB. | Wide values move out of line, so the heap keeps short pointers and the bytes accumulate in TOAST. |
| Read only `id` and `created_at` for 505 rows | 348 buffers and 1.204 ms (narrow) versus 332 buffers and 0.401 ms (wide). | A projection that stays on the main heap barely notices row width. |
| Read `length(payload)` for 505 rows | 351 buffers and 0.236 ms versus 2,352 buffers and 19.951 ms. | Touching a toasted value forces TOAST page reads, multiplying I/O. |
| Aggregate over every payload | 618 buffers and 4.154 ms versus 200,468 buffers and 580.848 ms. | The full storage footprint becomes I/O when the whole table is read. |

## Experiment 4: Hot And Cold Archiving

Most operational queries read recent data while most rows are old. Keeping one index over all time pays cache and maintenance cost for data that is rarely read. Partial indexes and partitioning reshape that cost.

The runnable experiment is [`benchmark/sql/archive.sql`](benchmark/sql/archive.sql), run with:

```bash
cd topics/database/table-growth/benchmark
./run-archive.sh 1000000
docker compose down
```

One million rows span 2020; `created_at >= 2020-12-01` selects 82,170 rows (8.22%).

### Archiving Result Interpretation

| Change | Observe in the local run | Interpretation |
| --- | --- | --- |
| Restrict the index to the hot slice | The `created_at` index fell from 31.6 MB to 2.6 MB for the 8.22% hot slice. | A partial index stores only keys that can match the predicate, so it is smaller to cache and maintain. |
| Partition the table by month | Local indexes totaled 34.6 MB, slightly more than the 31.6 MB full index. | Partitioning trades one large structure for many small ones and enables pruning, at some total-size overhead. |
| Run the recent-activity query | Full, partial, and partitioned plans each used about 4 buffers. | With a small `LIMIT` and an ordered index, the immediate query is cheap in every layout; the difference is the structure being maintained. |
| Run a cold six-month query | The partitioned plan appended six partitions. | Pruning removes irrelevant months, but a broad cold range still scans each matching partition. |

## Experiment 5: Concurrent Readers And Writers

Growth changes cache behavior. A table that fits in shared buffers answers every random read from memory; a larger table begins reading pages. This experiment uses `pgbench` to hold the workload fixed while the table size changes.

The harness is [`benchmark/sql/concurrency-setup.sql`](benchmark/sql/concurrency-setup.sql) plus the [`pgbench-read.sql`](benchmark/sql/pgbench-read.sql) and [`pgbench-write.sql`](benchmark/sql/pgbench-write.sql) scripts, run with:

```bash
cd topics/database/table-growth/benchmark
./run-concurrency.sh 100000
./run-concurrency.sh 1000000
docker compose down
```

Each case runs for 5 s after a `pg_stat_reset()`, at 1 and 8 clients.

### Concurrency Result Interpretation

| Change | Observe in the local run | Interpretation |
| --- | --- | --- |
| Grow from 100,000 to 1,000,000 rows at 1 read client | Heap reads appeared: 0 of 134,811 versus 25,909 of 142,460, while TPS stayed near 27-28k. | The larger working set no longer fits shared buffers, but `tmpfs` reads are cheap enough to keep throughput flat. |
| Raise read clients from 1 to 8 | Read TPS rose from about 27k to about 130k; write TPS from about 25k to about 90k. | Independent point access scales across cores until a shared resource saturates. |
| Keep writes uniform across keys | Write throughput did not collapse on the larger table. | Random updates to different rows do not contend on the same row or page. |

The buffer counters show the cache effect growth creates; elapsed time would diverge more on physical storage than on `tmpfs`.

## Detailed Explanation

Without an index, the lookup has to inspect the table until it finds qualifying rows. An index changes that work into an index traversal plus row lookups, which is usually a better trade when the predicate is selective enough. The index is not free: it consumes space and must be maintained by writes.

For a deep page, `OFFSET` expresses "walk in order, discard N rows, then return the next page." A cursor expresses "start after this known key." The latter avoids repeating the discard work as the position moves deeper, but it requires a stable, ordered cursor and does not naturally support jumping to an arbitrary page number.

The additional experiments show the same "work follows the data the access path must touch" principle in non-query places:

- Write cost is the sum of heap work and one index update per secondary index, plus WAL. Fillfactor only helps while a new tuple version stays on its page.
- Row width is storage and I/O that a projection can avoid or expose. Out-of-line TOAST values keep the main heap small but charge each access.
- Archiving changes which data the index and cache must cover, not the SQL. A partial index or partition is a smaller structure with the same lookup path.
- Concurrency reveals whether the working set fits in cache. Once it does not, reads appear; their latency then depends on the storage beneath the cache.

These are tendencies, not guarantees. Selectivity, cache state, row width, indexes, query plan choices, and the database engine all affect the result.

## Focus

This topic is not only about "optimizing SQL"; it is about understanding how engineering maintenance costs change as data grows.

## Next Additions

- Compare a covering index that includes `payload` with the heap-access plans in the row-width experiment.
- Add a mixed write workload with range scans and multi-statement transactions.
- Measure index build time, `VACUUM`, and bloat as updates accumulate.
- Add a moving hot window with a maintained partial index or managed partitions.
- Add lock contention by having concurrent writers target the same rows.
