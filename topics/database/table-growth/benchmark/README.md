# Table growth benchmark

These experiments run PostgreSQL 17.6 in Docker and create deterministic data for three related table-growth questions:

- `customer_id` equality lookup with and without an index.
- A page near the end of the table using `LIMIT/OFFSET` and cursor pagination.
- Sequential and random UUID primary keys compared with `bigint`.
- Finding an arbitrary x-th ordered row or distinct value.

Read cases are warmed once and then measured with `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)`. Write cases pre-generate their keys and also report WAL. This exposes execution strategy and work performed, not only elapsed time. The numbers are local observations, not a ranking of database products.

## Run

From the benchmark directory:

```bash
cd topics/database/table-growth/benchmark
./run.sh 100000
./run.sh 1000000
./run.sh uuid-ids 1000000
./run.sh kth-largest 1000000
```

Stop and remove the container after the experiment:

```bash
docker compose down
```

The original numeric-only form runs `table-growth`. The explicit equivalent is `./run.sh table-growth 100000`.

## Experiments

- Base lookup and pagination experiment: documented below.
- [UUID primary keys](uuid-ids.md): separates key width from insertion locality.
- [Finding the x-th largest value](kth-largest.md): compares index offsets with materialized ranks and clarifies duplicate semantics.

## Base Variables

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
- The base experiment does not measure insert cost; the UUID extension isolates primary-key insertion but not secondary-index or concurrent-write cost.
- Query latency is affected by the host, container runtime, PostgreSQL version, storage, and cache state. Repeat runs and compare plans and buffer counts rather than one number.
