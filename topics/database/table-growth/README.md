# Database table growth

This topic uses small experiments to understand which problems gradually appear as relational database tables grow.

A growing table does not only make queries slower. It raises write cost, increases storage and WAL, changes cache residency, and makes maintenance decisions (indexes, archiving, vacuum) more expensive. The experiments below separate those pressures so each one stays visible.

The read-only query experiments are recorded in [`result/2026-09-01-postgresql-17-darwin-arm64.md`](result/2026-09-01-postgresql-17-darwin-arm64.md). The write, row-width, archiving, and concurrency experiments are recorded in [`result/2026-09-19-postgresql-17-darwin-arm64.md`](result/2026-09-19-postgresql-17-darwin-arm64.md).

Each experiment starts with a schema diagram, so the table shape and the index portfolio under test are visible before the numbers. The diagrams are generated from the same definitions the benchmark SQL uses; see [`assets/README.md`](assets/README.md) to regenerate them.

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

![Experiment 1 schema: the orders table with a customer_id lookup index and a (created_at, id) pagination index](assets/query-cost-schema.svg)

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

All four cases return the same rows whether the table is small or large. What changes is the work the plan must do, and therefore the time.

| Rows | Case | Execution time | Work the plan performed | Shared buffers |
| ---: | --- | ---: | --- | ---: |
| 100,000 | Lookup, no index | 1.933 ms | `Seq Scan`, 100,000 rows tested | 1,725 |
| 100,000 | Lookup, indexed | 0.100 ms | 100 index entries, 100 heap rows | 102 |
| 100,000 | Deep `OFFSET` | 3.401 ms | 99,050 index entries walked, 50 returned | 383 |
| 100,000 | Cursor | 0.019 ms | 50 index entries | 4 |
| 1,000,000 | Lookup, no index | 25.454 ms | `Parallel Seq Scan`, 1,000,000 rows tested by 3 processes | 17,242 |
| 1,000,000 | Lookup, indexed | 0.171 ms | 100 index entries, 100 heap rows | 103 |
| 1,000,000 | Deep `OFFSET` | 35.948 ms | 999,050 index entries walked, 50 returned | 3,831 |
| 1,000,000 | Cursor | 0.014 ms | 50 index entries | 4 |

The times are worth reading as shapes rather than as figures to memorize:

- **The unindexed lookup scales with the table.** Ten times the rows cost about 13 times the time (1.933 ms to 25.454 ms), because the plan has no structure that says which rows match. Growth did not simply make the same plan slower, either: at 1,000,000 rows PostgreSQL replaced `Seq Scan` with `Parallel Seq Scan` and spread the scan over three processes, which is why the time grew a little faster than 10x rather than 10x exactly. Parallelism bought back some of the increase, at the cost of more CPU and more buffers in flight.
- **The indexed lookup stays flat.** 0.100 ms at 100,000 rows and 0.171 ms at 1,000,000 rows: the plan touches about 100 index entries and 100 heap rows at either size, and a ten-times-larger B-tree adds only about one level to descend. This is the flat curve the other three cases do not have. Note also that this query was *slower* at 100,000 rows than the cursor was at 1,000,000 rows, which is a useful reminder that "X ms" only means something next to the work it bought.
- **Deep `OFFSET` grows with table size and with page depth.** Walking 999,050 entries at the one-million-row size cost 35.948 ms against 3.401 ms for 99,050 entries at the small size, and visited ten times the buffers. Use the buffer and visited-entry counts, not the elapsed times, to compare these two rows: a single measured execution on `tmpfs` is accurate enough to show that the work grew by an order of magnitude, but not accurate enough to say the per-entry cost changed.
- **The cursor stays flat too.** 0.019 ms and 0.014 ms, 4 buffers each, 50 entries each. The seek lands near the boundary and the plan produces the page, so neither the row count nor the page depth enters the cost. Against `OFFSET` at 1,000,000 rows that is roughly a 2,500x difference for the identical result set.

The practical reading is that two queries with the same result can have different growth curves, and it is the curve, not the current reading, that decides when a query becomes unacceptable. A 0.171 ms lookup is not a problem at one million rows and is still not a problem at ten million; the 35.948 ms page is the one that needs a different access path before its table grows again.

These are tendencies, not guarantees. The curve depends on how selective the predicate is: a lookup index pays off because about 100 of 1,000,000 rows match. A predicate matching a large fraction of the table can make a scan the cheaper plan, and the planner will choose it. See [`result/2026-09-01-postgresql-17-darwin-arm64.md`](result/2026-09-01-postgresql-17-darwin-arm64.md) for the plan shapes and caveats behind these numbers, including the `tmpfs` storage that keeps these absolute times low.

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

![Experiment 2 schema: insert_none, insert_one, insert_three, append_one, update_fillfactor and update_default](assets/write-path-schema.svg)

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

Read as time per row, the three inserts cost 0.88 µs with no secondary index, 1.05 µs with one, and 1.94 µs with three. The additive part of that is the point: the first index added about 0.17 µs per row, and the next two added about 0.45 µs per row between them. Those two are not equal to each other either. `insert_three` indexes `customer_id`, `created_at`, and `status`, and the recorded 5.34 MB index total is not broken down per index, so this run cannot say which of the three dominated. What it does show is that cost followed the index count rather than a fixed rate per index.

WAL is the more transferable half of this row, because bytes written do not depend on the CPU of this machine. Roughly 190 B per row becomes 198 B and then 329 B, so the third index costs about as much WAL as the first two together.

One qualification belongs here. These are single measured statements, and the gap between the zero-index and one-index runs is 17 ms — enough to rank the cases, not enough to assert that an index costs 0.17 µs per row on another machine. The ordering is the finding; the marginal figure is mostly an artifact of this run.

The append case moves only the destination. The same 100,000 rows cost 127.866 ms instead of 105.049 ms, about 22% more, or 1.28 µs per row against 1.05 µs. A modest increase for a table more than ten times larger matches the plan: the batch still writes one heap tuple and one index entry per row, but each new key now descends a deeper B-tree and lands in a larger heap. Table size enters per-row write cost slowly, through the depth and locality of the structures the write maintains, not through how many rows the batch contains.

The update cases have no recorded execution time, so read them as bytes and tuple counts rather than milliseconds. All three rewrite 10,000 of 10,000 rows and insert nothing into an empty table, which makes WAL the honest measure of how much index maintenance the update forced. On an unindexed column, fillfactor 80 wrote 1.08 MB against 3.13 MB at fillfactor 100 — about 2.9x less WAL — while making 10,000 heap-only updates instead of 0.

The buffer counter needs one caveat before it is used as evidence. `pg_stat_reset()` runs once before all three update statements, so the counters are cumulative rather than per statement; the fillfactor-100 figure is its own measurement, but the later cases include the pages the earlier ones touched. That makes the pair 22,858 and 71,429 interesting rather than conclusive: the indexed update at fillfactor 80 visited about the same number of buffers as the unindexed update at fillfactor 100, and both were zero-HOT. The reading that survives the caveat is that a changed indexed value costs about what a tuple rewrite with no room for it costs, regardless of the free space sitting on the page.

Across all four write cases the honest ranking is by WAL and heap-only counts, not by milliseconds: those two move with the mechanism the experiment is about, while a single measured statement on a warm `tmpfs` database moves with the machine as well.

### Write Source And Pseudocode Walkthrough

[`benchmark/sql/writes.sql`](benchmark/sql/writes.sql) builds the same schema three times and changes only the secondary indexes:

```sql
CREATE INDEX insert_one_customer_idx ON insert_one (customer_id);

CREATE INDEX insert_three_customer_idx ON insert_three (customer_id);
CREATE INDEX insert_three_created_idx ON insert_three (created_at);
CREATE INDEX insert_three_status_idx  ON insert_three (status);
```

Each measured insert streams the same rows:

```sql
EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF)
INSERT INTO insert_three (id, customer_id, created_at, status, payload)
SELECT g, (g * 7919) % 100000, timestamp '2020-01-01' + g * interval '1 second', 'new', repeat('x', 40)
FROM generate_series(1, :batch::bigint) AS g;
```

There is no access path for the planner to choose, so the plan text stays identical. The executor still writes one heap tuple and one entry per index for every generated row, and `WAL: records` with `bytes` reports that work. That is why only the index count and the WAL/buffer numbers change between the three inserts.

The append case keeps one index and changes only where the rows land:

```sql
-- prefill, outside the measurement
INSERT INTO append_one (...)
SELECT g, ... FROM generate_series(1, :rows::bigint) AS g;

-- measured append
EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF)
INSERT INTO append_one (...)
SELECT g, ... FROM generate_series(:rows::bigint + 1, :rows::bigint + :batch::bigint) AS g;
```

The batch size is unchanged, but each new key now descends a taller B-tree and may split an internal page, which appears as extra buffers and WAL.

The update cases differ only in `fillfactor` and in whether the changed column is indexed:

```sql
CREATE TABLE update_fillfactor (...) WITH (fillfactor = 80);
UPDATE update_fillfactor SET payload = repeat('y', 40) WHERE id % 10 = 0;      -- unindexed
UPDATE update_fillfactor SET customer_id = customer_id + 1 WHERE id % 10 = 0;  -- indexed
```

`fillfactor = 80` leaves about 20% free space per page. A new tuple version that fits stays on its page, so PostgreSQL can keep the existing index entries pointing through a heap-only tuple chain and skip every secondary index. When the updated column is indexed, its value changes and a new index entry is unavoidable. `pg_stat_get_tuples_hot_updated` counts exactly those heap-only updates, which is why the same 10,000 unindexed updates wrote 1.08 MB of WAL at fillfactor 80 and 3.13 MB at fillfactor 100.

## Experiment 3: Row Width And TOAST

Payload width decides whether values stay on the main heap page or move to out-of-line TOAST storage. A query that never touches the wide column pays little; a query that does pays in extra page reads.

![Experiment 3 schema: width_narrow with a 40 byte payload versus width_wide with a 6.4 kilobyte STORAGE EXTERNAL payload](assets/row-width-schema.svg)

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

The three query rows differ in whether the elapsed times are worth reading, and the buffer counts say which ones are:

- **The narrow projection is a control, and its times are noise.** 1.204 ms against 0.401 ms looks like a 3x win for the wide table, but the buffer counts are 348 against 332, a 5% difference, and the plan reads the same columns from the same heap in both cases. A single execution at the sub-millisecond scale on a warm `tmpfs` cannot separate those two numbers. Read this row as "equal," and read the next two rows for the actual effect.
- **Touching the payload is where the plan changes shape.** `length(payload)` reads 351 buffers on the narrow table and 2,352 on the wide one, and the times track that gap: 0.236 ms against 19.951 ms, about 85x. Per row over 505 rows that is roughly 0.5 µs against 39.5 µs. The wide value is not in the heap, so the executor must follow each pointer into TOAST storage, which is why both the buffers and the time move together. When a number and its buffer count agree, the timing is describing work rather than scheduling.
- **The aggregate turns the storage table into a cost, but not proportionally.** The narrow table read 618 buffers in 4.154 ms; the wide table read 200,468 buffers in 580.848 ms. The page count grew about 324x while the time grew about 140x, and neither number matches the 61x storage ratio. That gap is informative rather than contradictory: the wide table's extra buffers are TOAST pages reached by pointer, and the two plans are spending their pages on different things, so size, pages, and time are three related but distinct measurements. The one thing all three agree on is that the wide table's full footprint has to be paid by anything that reads every payload.

The row that matters for a decision is the second one: a projection that avoids `payload` costs the same on both tables, and one that touches `payload` costs about 85 times more time and 6.7 times more buffers on the wide table. Row width is therefore a property of the query, not of the table. The wide table occupies 61 times the space and can still answer a heap-only projection at the price of the narrow one, so the question is never "is this table too wide," it is "which queries touch the wide column." Storing a large column out of line is what buys that gap, and it also means that anything reading every payload must pay it.

The absolute times here depend heavily on `tmpfs`. The buffer counts and the ratios between them would survive a move to physical storage; the millisecond figures would not. Where a timing and its buffer count disagree, this run is the reason to trust the count.

### Row Width Source And Pseudocode Walkthrough

[`benchmark/sql/toast.sql`](benchmark/sql/toast.sql) gives both tables identical columns and changes only the payload construction and its storage mode:

```sql
ALTER TABLE width_wide ALTER COLUMN payload SET STORAGE EXTERNAL;

INSERT INTO width_narrow (id, bucket, created_at, payload)
SELECT g, (g * 7919) % 10000, timestamp '2020-01-01' + g * interval '1 second', repeat('n', 40)
FROM generate_series(1, :rows::bigint) AS g;

INSERT INTO width_wide (id, bucket, created_at, payload)
SELECT g, (g * 7919) % 10000, timestamp '2020-01-01' + g * interval '1 second', repeat(md5(g::text), 200)
FROM generate_series(1, :rows::bigint) AS g;
```

`STORAGE EXTERNAL` disables compression, so the experiment measures out-of-line width rather than compressibility. A value above the roughly 2 kB TOAST threshold is stored in the TOAST relation, and the heap tuple keeps only a small pointer. The size query makes that split explicit:

```sql
pg_total_relation_size(c.oid) - pg_relation_size(c.oid) - pg_indexes_size(c.oid) AS toast_bytes
```

That subtraction is why the wide main heap is smaller than the narrow one while its `toast_bytes` is about 414 MB.

The two access paths differ by which columns the query touches:

```sql
SELECT id, created_at   FROM width_wide WHERE bucket BETWEEN 500 AND 600;  -- stays on the heap
SELECT id, length(payload) FROM width_wide WHERE bucket BETWEEN 500 AND 600;  -- must read TOAST
```

A toasted datum can be streamed without being detoasted until a function actually consumes it. That is why the experiment measures `length(payload)` rather than a bare `SELECT payload`: the plan only reflects TOAST work when the value is read, which is why this case and the full-table aggregate show the wide table's I/O.

## Experiment 4: Hot And Cold Archiving

Most operational queries read recent data while most rows are old. Keeping one index over all time pays cache and maintenance cost for data that is rarely read. Partial indexes and partitioning reshape that cost.

![Experiment 4 schema: archive_full, archive_full_partialindex and archive_part layouts for hot and cold data](assets/archiving-schema.svg)

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
| Run a cold six-month query | The partitioned plan appended six partitions, visiting 5,557 shared hits, 601 reads and 516 writes in 15.044 ms. | Pruning removes irrelevant months, but a broad cold range still scans each matching partition. |

The two queries in this experiment answer different questions, and only one of them is a timing question.

The recent-activity query is a control, not a ranking. 0.026 ms on the full index, 0.019 ms on the partial index, 0.019 ms on the December partition, with 4-5 buffers each. These three numbers are the same number, and that is what the `LIMIT 100` plus an ordered index guarantees: the plan seeks to the hot boundary and reads 100 entries, so the size of the structure behind it never enters the cost. The measurement is useful because it rules something out — adopting a partial index or partitioning does not slow the immediate query — and it settles nothing about which layout is faster. The 1.4x spread between the first and second figure is scheduling noise, not a result.

The tradeoff is in the sizes instead: 31.6 MB, 2.6 MB, 34.6 MB. A partial index over an 8.22% slice came out about 12 times smaller, which is the cache and maintenance argument, and partitioning came out about 10% larger than the single full index, which is the overhead argument. Neither figure is a latency, so neither needs a stopwatch.

The cold query is the one place a time is recorded, and it should be read as a description of a plan rather than as a speed. 15.044 ms, 5,557 shared hits, 601 reads, and 516 written buffers over a `Parallel Append` across six of twelve partitions. Pruning did something real: it excluded six months that could not match, and the plan lists only the six that could. But the query still had to read every partition that could match, because a six-month range covers a large fraction of each month's rows, no index covers a month efficiently at that selectivity, and a scan is what remains. Note what is missing from this run: there is no full-table equivalent of this query. Without that baseline, 15.044 ms cannot be presented as a win for partitioning. It is the cost of a broad range in this layout, and the comparison that would test pruning is the same query against an unpartitioned table.

The practical reading is that archiving changes which structure must be maintained and cached, not how fast a point-adjacent query runs. Choose the layout by which data the index must cover and by what has to be vacuumed and rebuilt, and check the cold-range case explicitly because that is where partitioning still pays full price.

### Archiving Source And Pseudocode Walkthrough

[`benchmark/sql/archive.sql`](benchmark/sql/archive.sql) gives the same rows three layouts. The first index covers all time:

```sql
CREATE INDEX archive_full_created_idx ON archive_full (created_at, id);
```

The second stores only the hot slice:

```sql
CREATE INDEX archive_full_partial_created_idx
    ON archive_full_partialindex (created_at, id)
    WHERE created_at >= timestamp '2020-12-01';
```

Because the predicate is part of the index definition, PostgreSQL does not store entries for older rows, and a query whose predicate implies the same condition can still use the index. That is why `pg_relation_size('archive_full_partial_created_idx')` returns about 2.6 MB instead of 31.6 MB.

The third layout partitions on the same boundary:

```sql
CREATE TABLE archive_part (...) PARTITION BY RANGE (created_at);
CREATE TABLE archive_part_2020_12 PARTITION OF archive_part
    FOR VALUES FROM ('2020-12-01') TO ('2021-01-01');
CREATE INDEX archive_part_created_idx ON archive_part (created_at, id);
```

`CREATE INDEX` on the partitioned parent creates one index per partition. At plan time PostgreSQL compares the query predicate with the partition bounds and can exclude every month that cannot match, which is why the cold January-to-June query lists only six partitions in its `Parallel Append` instead of all twelve.

## Experiment 5: Concurrent Readers And Writers

Growth changes cache behavior. A table that fits in shared buffers answers every random read from memory; a larger table begins reading pages. This experiment uses `pgbench` to hold the workload fixed while the table size changes.

![Experiment 5 schema: the bench_orders table used by the pgbench read and write scripts](assets/concurrency-schema.svg)

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

The TPS column has to be read next to the latency column, because throughput alone can hide the mechanism it is supposed to show.

Consider the 1-client point read across the two table sizes: 26,968 TPS at 0.037 ms versus 28,498 TPS at 0.035 ms. The larger table is not slower. Meanwhile `heap_blks_read` went from 0 to 25,909, about 18% of heap accesses. If timing is the question, growth changed nothing here. If capacity is the question, growth already changed the answer. An 18% miss rate served by `tmpfs` shows up as no latency at all, and the same misses served by a network-attached disk would not. The counters are where growth is visible now; the latency column is where it would become visible later.

The updates show the same pattern with a smaller read share: 23,086 reads out of 388,965 heap accesses at 1 client, about 6%, versus 0 at 100,000 rows, again with essentially unchanged throughput (24,826 against 24,847 TPS). Write statements touch more heap pages per transaction than reads do, which is why the miss rate is lower, but the direction is the same: the cache stopped covering the working set and the workload did not notice.

Scaling tells a similar story about how much of the machine is being used. Going from 1 to 8 clients raised reads from about 27k to about 130k TPS, roughly 4.8x, and writes from about 25k to about 90k, roughly 3.6x. Eight times the clients produced between four and five times the transactions, so something shared began to bound the result well before eight cores were busy. That is the expected shape for this workload — independent point access with no row-level contention — but the shortfall is real and this run does not identify which resource caused it.

Latency across the same scaling: 0.037 ms to 0.062 ms for reads and 0.040 ms to 0.089 ms for updates, about 1.7x and 2.2x worse. That is latency growing while throughput grows sublinearly, which is what a queue looks like. The two numbers are one measurement, not two.

The practical reading is that growth can be invisible in latency on a fast storage layer while it is plainly visible in cache behavior, and the counters are what make the difference legible. Establishing that throughput stays flat through a ten-times growth in table size is useful evidence here; generalizing it to a disk-backed deployment is not supported by this run, because the reads this experiment introduced never actually paid a seek.

### Concurrency Source And Pseudocode Walkthrough

[`benchmark/sql/concurrency-setup.sql`](benchmark/sql/concurrency-setup.sql) builds one table and resets statistics so each case measures only its own activity:

```sql
CREATE TABLE bench_orders (...) WITH (fillfactor = 80);
CREATE INDEX bench_orders_customer_idx ON bench_orders (customer_id);
VACUUM (ANALYZE) bench_orders;
SELECT pg_stat_reset();
```

The two `pgbench` scripts keep one statement per transaction and randomize the key:

```sql
\set id random(1, :rows)
SELECT id, customer_id, created_at, payload FROM bench_orders WHERE id = :id;
```

```sql
\set id random(1, :rows)
UPDATE bench_orders SET counter = counter + 1 WHERE id = :id;
```

[`benchmark/run-concurrency.sh`](benchmark/run-concurrency.sh) runs each script at 1 and 8 clients, then reads the counters that explain the result:

```sh
$PGBENCH --no-vacuum --client="$clients" --jobs="$clients" --time=5 --protocol=prepared \
  --define=rows="$ROWS" --file "/benchmark/pgbench-$mode.sql"
$PSQL -t -A -c "SELECT heap_blks_hit, heap_blks_read, idx_blks_hit, idx_blks_read \
  FROM pg_statio_user_tables WHERE relname = 'bench_orders';"
```

A primary-key point lookup almost always finds its index page; the heap page may or may not be cached. At 100,000 rows the `heap_blks_read` column stays at 0, while at 1,000,000 rows it recorded 25,909 of 142,460 accesses. The TPS and latency numbers are the throughput counterpart of those counters.

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
