# Table growth benchmark

This experiment runs PostgreSQL 17.6 in Docker and creates a deterministic `orders` table for two access patterns:

- `customer_id` equality lookup with and without an index.
- A page near the end of the table using `LIMIT/OFFSET` and cursor pagination.

Each case is warmed once and then measured with `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)`. This exposes both execution time and the amount of data visited by the plan. The numbers are local observations, not a ranking of database products.

## Run

From the benchmark directory:

```bash
cd topics/database/table-growth/benchmark
./run.sh 100000
./run.sh 1000000
```

Stop and remove the container after the experiment:

```bash
docker compose down
```

## Variables

| Variable | Values | Reason |
| --- | --- | --- |
| Row count | `100000`, `1000000` | Expose how work changes as the table grows |
| Lookup index | absent, `customer_id` | Compare scanning with indexed search |
| Page position | 20 pages before the end | Make skipped rows visible without huge data |
| Pagination | `OFFSET`, cursor | Compare skip-and-discard with a range condition |

The script uses deterministic expressions and a fixed 80-byte payload. It rebuilds the table on every invocation. PostgreSQL data lives on `tmpfs`, keeping generated data out of the repository and allowing `docker compose down` to discard it completely.

## What to inspect

For the lookup, inspect `Seq Scan` versus `Bitmap Index Scan` or `Index Scan`, along with `Buffers` and `Rows Removed by Filter`. For pagination, compare how many rows the index scan visits: `OFFSET` must produce the skipped rows before the `Limit` can discard them, while the cursor adds an `Index Cond` that starts near the requested position.

## Limits

- The client runs inside the same Compose project, so execution time mostly reflects server work rather than application network latency.
- PostgreSQL planner choices depend on statistics, cost settings, memory, cache state, and data distribution. A small or low-selectivity table may reasonably choose a sequential scan even when an index exists.
- The selected page is near the end, so this intentionally demonstrates a deep-page case rather than all pagination workloads.
- Indexes improve some reads but add storage and write/maintenance work; this benchmark does not measure insert cost yet.
- Query latency is affected by the host, container runtime, PostgreSQL version, storage, and cache state. Repeat runs and compare plans and buffer counts rather than one number.
