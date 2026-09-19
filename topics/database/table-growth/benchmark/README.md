# Table growth benchmark

This directory runs PostgreSQL 17.6 in Docker and creates deterministic data for several table-growth questions:

- `run.sh`: `customer_id` equality lookup with and without an index, and deep pagination with `LIMIT/OFFSET` versus a cursor.
- `run-writes.sh`: insert and update cost with 0, 1, and 3 secondary indexes, append cost on a large table, and heap-only tuple updates.
- `run-toast.sh`: narrow versus wide payloads, out-of-line TOAST storage, and the plans that do or do not touch the wide column.
- `run-archive.sh`: one full index, a partial index on the hot slice, and a monthly partitioned table.
- `run-concurrency.sh`: `pgbench` point reads and point updates at 1 and 8 clients against small and large tables.

Each case is warmed or prepared and then measured. Statements use `EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF)`, which exposes execution strategy, work performed, WAL volume, and sometimes elapsed time. The numbers are local observations, not a ranking of database products.

## Run

From the benchmark directory:

```bash
./run.sh 100000
./run.sh 1000000

./run-writes.sh 1000000 100000
./run-toast.sh 50000
./run-archive.sh 1000000
./run-concurrency.sh 100000
./run-concurrency.sh 1000000
```

Stop and remove the container after the experiments:

```bash
docker compose down
```

Only one runner needs to start the container; the others reuse it. Each SQL file drops and rebuilds only its own tables, so runners can be executed in any order.

## Variables

| Runner | Variable | Values | Reason |
| --- | --- | --- | --- |
| `run.sh` | Row count | `100000`, `1000000` | Expose how work changes as the table grows |
| `run.sh` | Lookup index | absent, `customer_id` | Compare scanning with indexed search |
| `run.sh` | Pagination | `OFFSET`, cursor | Compare skip-and-discard with a range condition |
| `run-writes.sh` | Prefill rows | `1000000` by default | Size of the table that receives the append batch |
| `run-writes.sh` | Batch rows | `100000` by default | Insert and update batch measured per case |
| `run-toast.sh` | Row count | `50000` by default | Keep the wide table's TOAST footprint manageable |
| `run-archive.sh` | Row count | `1000000` by default | Spread rows across twelve monthly partitions |
| `run-concurrency.sh` | Row count | `100000`, `1000000` | Compare a cached working set with an oversized one |

The scripts use deterministic expressions and a fixed payload. They rebuild their tables on every invocation. PostgreSQL data lives on `tmpfs`, keeping generated data out of the repository and allowing `docker compose down` to discard it completely.

## What to inspect

- Queries: `Seq Scan` versus `Bitmap Index Scan` or `Index Scan`, `Buffers`, and `Rows Removed by Filter`. For pagination, compare how many rows the index scan visits.
- Writes: `Execution Time`, `WAL` bytes, `Buffers`, and `pg_stat_get_tuples_hot_updated` for the update cases.
- Row width: `pg_relation_size`, `pg_indexes_size`, and the difference up to `pg_total_relation_size` for TOAST, plus buffers when the payload is and is not touched.
- Archiving: the size of each `created_at` index, the chosen plan, and whether the planner prunes partitions.
- Concurrency: `pgbench` TPS and latency averages, plus heap and index buffer hits and reads from `pg_statio_user_tables`.

## Limits

- The client runs inside the same Compose project, so execution time mostly reflects server work rather than application network latency.
- PostgreSQL planner choices depend on statistics, cost settings, memory, cache state, and data distribution. A small or low-selectivity table may reasonably choose a sequential scan even when an index exists.
- `tmpfs` reads are memory-backed, so growth-driven cache misses do not carry the latency they would on physical storage.
- Write timings are single measured statements; WAL bytes, buffers, and plan shape are the more stable observations.
- Index size depends on key distribution and B-tree deduplication, not only on the number of rows.
- `pgbench` uses one statement per transaction. Real workloads include joins, range scans, and longer transactions.
- The partial index covers a fixed boundary, and the partitioned table uses fixed monthly ranges; both need maintenance in production.
- Query latency is affected by the host, container runtime, PostgreSQL version, storage, and cache state. Repeat runs and compare plans, rows, buffers, and WAL rather than one number.
