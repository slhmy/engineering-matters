# Clustered primary-key rows versus a separate heap

Status: the 100,000-row experiment completed on 2026-10-01 with PostgreSQL 17.11 and MySQL 8.4.11. All full-table and query fingerprints passed. See the [result report and raw evidence](result/2026-10-01-postgresql17-mysql84-darwin-arm64.md).

## Story

An order-history endpoint reads the next 1,000 records by numeric ID and returns their payloads. Another endpoint retrieves roughly 100 orders for a customer-like bucket. Does storing the row in the primary-key B-tree change the work?

The intuitive claim is “both engines have B-tree indexes, so the reads are the same.” The useful distinction is what happens **after finding an index entry**:

- MySQL 8.4 with InnoDB: primary-key leaves contain row data; a secondary index carries the primary key used to locate the clustered record when needed
- PostgreSQL 17: a primary-key B-tree is separate from its heap; payload reads normally visit heap tuples. A secondary index can point to heap tuples without a second primary-key search

This predicts different access work, not a universal winner. Logical leaf order does not mean adjacent physical disk sectors. Row layout, MVCC and cache behavior still matter.

## Controlled matrix

Each engine receives identical deterministic records in two fresh tables:

| Factor | Values |
| --- | --- |
| Engine | PostgreSQL 17; MySQL 8.4, explicitly InnoDB |
| Insertion order | ascending ID; deterministic SHA-256 shuffled ID |
| Rows | 100,000 by default |
| Row | BIGINT ID, INTEGER bucket, 256 ASCII payload bytes |
| Indexes | primary key on ID; B-tree on (bucket, ID) |
| Query | PK range + payload; secondary equality + payload; secondary covering projection |
| Load batch | 1,000 VALUES rows; indexes exist before loading |
| Repetition | 3 unreported warmups, 10 reported runs; randomized round order |

A bucket is `(id * 7919) % 1000`; bucket 42 has exactly 100 matches at 100k rows. Payload is four copies of SHA-256(decimal ID). The 1,000-row PK window begins at ID 50,000. No updates, concurrent writers, real user data, out-of-line large values, or external databases are involved.

The sequential table is an essential control: PostgreSQL's heap can already be well correlated with ID following an ascending load. A shuffled load breaks that correlation without changing the SQL or records. MySQL maintains logical clustered key order, although insertion order can change page occupancy and splits. This is a comparison of resulting layouts, not a measurement of insert throughput.

## Run

Needs Python 3.9+ (standard library only), Docker Engine/Desktop, and Docker Compose v2 supporting `up --wait`. Running pulls official `postgres:17` and `mysql:8.4` images if necessary and starts two local isolated containers. Expect a few hundred MB of database storage plus image downloads; reserve several GB and at least 2 GB available memory. No ports are published to the host. The static password is disposable and only for these isolated lab containers.

From the repository root after pulling:

```bash
cd topics/database/clustered-index-vs-heap/benchmark
./run.sh
```

The wrapper defaults to 100,000 rows and a fresh timestamped result directory. Optionally use `./run.sh 1000000` for one million rows. From the topic directory, the equivalent explicit command and offline unit tests are:

```bash
python3 -m unittest discover -s code -v
python3 code/lab.py --out result/run-100k --run
```

Output directories must not exist; a run never overwrites results. Each execution uses a random Compose project name and its own named volumes. A failure leaves its containers and data available for diagnosis. The script prints its exact scoped stop command and writes it to `stop-command.txt` as soon as the project is allocated. Stopping does not delete the named volumes. If you choose to discard only that run's data, inspect and execute its `delete-this-run-command.txt`; no generic prune/reset command is used.

Generate/inspect the SQL without Docker or starting any database:

```bash
python3 code/lab.py --out result/generated-100k
```

To vary size or range width, create another fresh run:

```bash
python3 code/lab.py --rows 1000000 --range-rows 1000 --out result/run-1m --run
```

The image tags select major/LTS series and can advance. Every actual run records database versions and immutable local image IDs. For repeatable cross-machine runs, set `PG_IMAGE` and `MYSQL_IMAGE` to the same verified official image digests (for example `postgres@sha256:...`) before running. Do not copy a made-up digest. Docker/platform/architecture information is saved; record host disk type, Docker VM memory/CPU limit and competing workload beside your result report.

## Query source and what to inspect

Exact timed queries are saved as `queries.sql`. For each table they have this shape:

```sql
SELECT id, bucket, payload FROM rows_seq WHERE id >= 50000 AND id < 51000;
SELECT id, bucket, payload FROM rows_seq WHERE bucket = 42;
SELECT id, bucket FROM rows_seq WHERE bucket = 42;
```

There is deliberately no ORDER BY: this isolates retrieval from presentation sorting. Verification canonicalizes result order outside the DB. If the product requires sorted output, add a separately labeled experiment with its actual ordering requirement.

1. **PK range with payload:** inspect PG Index Scan, Bitmap Heap Scan or Seq Scan and its buffer work. Inspect MySQL's clustered PRIMARY access. Compare sequential versus shuffled **within each engine** before making an engine-to-engine claim
2. **Secondary with payload:** both engines need data outside the selected secondary index. PG accesses heap tuples; InnoDB locates clustered records through their primary keys. A plan may not print every internal record lookup as a separate operator
3. **Covering projection:** `(bucket,id)` can provide both selected columns. PG's index-only path also requires visibility checks. The script runs `VACUUM (ANALYZE)` after loading, with no later writes, then captures actual Heap Fetches in plans. Check this counter rather than assuming zero. MySQL covering reads can also require clustered access under MVCC conditions; this read-only fresh-load case avoids competing updates

No forced indexes or disabled sequential scans are used. PG parallel query and JIT are disabled explicitly to simplify the single-client illustration; normal optimizer access-path choices remain enabled. A scan or different chosen plan is a result to explain, not a reason to force the expected plan.

## Measurements and correctness

- `manifest.json`: independent expected row counts and SHA-256 hashes
- `verified-checksums.json`: all four full tables and every query compared to the independent generator, not merely to each other
- `plans/`: every raw warmup and measured EXPLAIN plan
- `measurements.csv`, `summary.json`: all measured samples and median/min/max
- `versions.json`, `environment.json`, settings and sizes: engine versions, local image IDs, host/runtime configuration, storage estimates and PG heap correlation
- `execution-order.json`: exact measurement sequence
- `STATUS.txt`: completion marker; only a successful DB run writes DATABASE RUN COMPLETED

The runner aborts on a checksum, root loop-count or PostgreSQL root row-count mismatch. MySQL can round displayed plan row counts, so its exact correctness check uses the independently verified SELECT result, while the displayed root count is retained for inspection. PG uses `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`; MySQL uses `EXPLAIN ANALYZE FORMAT=TREE`.

The two reported time fields are **not identical instruments**: PG reports overall Execution Time; MySQL reports the root iterator's last-row time. Both include instrumentation overhead, while MySQL's field has a different scope. Raw plans and the measurement name are retained. No docker-exec/process startup wall time is mislabeled as SQL latency. Neither measurement is application/network end-to-end latency. Do not derive a precise cross-engine speedup from these fields; use them primarily for within-engine contrasts and plan interpretation.

## Predictions tested in the first run

- Shuffling is likely to spread PG's qualifying heap rows over more pages for the same PK range; a bitmap path may mitigate repeated heap page visits
- InnoDB's primary range can traverse ordered clustered leaves containing payload, although shuffled insertion can produce different occupancy and fragmentation
- The sequential PG control may narrow the apparent clustered-versus-heap difference
- A covering secondary read may reduce row-fetch work in both engines; PG Heap Fetches must be checked
- With 100k rows and warmed memory, wall-clock differences may be small or noisy even when access paths differ

The [first result report](result/2026-10-01-postgresql17-mysql84-darwin-arm64.md) records these observations under the default 100k-row matrix:

- PostgreSQL's PK range changed from Index Scan after ascending insertion to Bitmap Heap Scan after shuffled insertion. Shared buffer hits rose from 46 to 888, including 879 exact heap blocks in the shuffled plan; median Execution Time rose from 0.2135 to 1.3800 ms. All measured PostgreSQL plans had zero shared reads.
- MySQL used a PRIMARY range scan for both insertion orders. Its root last-row median was 0.1650 ms ascending and 0.1955 ms shuffled. Estimated clustered storage was larger after shuffled insertion (49.58 versus 30.56 MiB).
- PostgreSQL covering reads had zero Heap Fetches in all measured samples, using 4–5 shared hits instead of 101–104 for secondary payload reads. MySQL reported covering index lookups with lower times than its non-covering lookups.

The evidence supports locality and covering-index explanations in this warmed, read-only run. PostgreSQL and MySQL use different timing instruments; these figures are not a cross-engine speedup comparison. All 120 measured samples, 36 warmup plans, fingerprints, and runtime metadata are retained in `result/2026-10-01-100k/`. The large generated load SQL stays in ignored local run directories. Four offline unit tests also passed; larger row counts and write/concurrency scenarios remain unmeasured.

## Boundaries and common misconceptions

This is a warmed, read-only, low-concurrency demonstration. Full-table correctness verification and explicit warmups run before measurements, so this is **not** a cold-cache test. Restarting a container would not reliably flush host/VM/filesystem caches. At larger sizes not every page is guaranteed resident; “warmed” describes the protocol, not guaranteed cache hits.

The 128 MiB PG shared buffer and 128 MiB InnoDB buffer pool settings are not equal total memory budgets: PG also depends on OS page caching, and engine memory architectures differ. Page sizes differ too. PostgreSQL BUFFERS counts are not interchangeable with MySQL counters; do not compare them as equal I/O units or add parent/child counts. No MySQL-equivalent physical buffer count is invented. MySQL information-schema storage lengths are estimates; PG relation/index sizes have different accounting.

Updates, visibility map churn, long transactions, wider primary keys, cache misses and concurrency can change results. A 100k warm test does not answer throughput or production capacity. To test maintained heap clustering separately, a future PG-only arm could run CLUSTER and then repeat the same queries; it rewrites the table and is not automatically maintained afterward. It is intentionally outside this initial matrix.

## Related labs and sources

This lab is a sibling of [table growth](../table-growth/) and [point versus range scan](../point-vs-range-scan/). It changes the storage model and insertion order while keeping records and query shapes fixed.

- [Repository lab principles](https://github.com/slhmy/engineering-matters/blob/main/AGENTS.md)
- [Existing table-growth lab](https://github.com/slhmy/engineering-matters/blob/main/topics/database/table-growth/README.md)
- [PostgreSQL 17 index-only scans and heap layout](https://www.postgresql.org/docs/17/indexes-index-only-scans.html)
- [PostgreSQL 17 visibility map](https://www.postgresql.org/docs/17/storage-vm.html)
- [InnoDB clustered and secondary indexes](https://dev.mysql.com/doc/refman/8.4/en/innodb-index-types.html)
- [MySQL EXPLAIN ANALYZE](https://dev.mysql.com/doc/refman/8.4/en/explain.html)
