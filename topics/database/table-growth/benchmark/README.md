# Table growth benchmark

This is a SQLite experiment with no third-party dependencies. It creates a deterministic `orders` table and measures the median warm-query time for two access patterns:

- `customer_id` equality lookup with and without an index.
- A page near the end of the table using `LIMIT/OFFSET` and cursor pagination.

The numbers are observations from the local machine, not a ranking of database products.

## Run

From the repository root:

```bash
python3 topics/database/table-growth/benchmark/run.py --rows 100000
python3 topics/database/table-growth/benchmark/run.py --rows 1000000 --json
```

The default run uses a temporary database. Keep a database file when inspecting it manually:

```bash
python3 topics/database/table-growth/benchmark/run.py --rows 100000 --database /tmp/table-growth.db
```

## Variables

| Variable | Values | Reason |
| --- | --- | --- |
| Row count | `100000`, `1000000` | Expose how work changes as the table grows |
| Lookup index | absent, `customer_id` | Compare scanning with indexed search |
| Page position | 20 pages before the end | Make skipped rows visible without huge data |
| Pagination | `OFFSET`, cursor | Compare skip-and-discard with a range condition |

The script uses a fixed random seed and a fixed payload size. It warms each query five times and reports the median of subsequent samples. The database is rebuilt for every invocation.

## What to inspect

The output includes `EXPLAIN QUERY PLAN`. For the lookup, SQLite should report a table scan without the index and an index search with it. For pagination, both forms can use the `(created_at, id)` index; the important difference is that `OFFSET` still has to walk past the skipped rows, while the cursor starts from a known range position.

## Limits

- SQLite is an embedded database, so this does not model network latency, a server buffer pool, replicas, or concurrent writers.
- The selected page is near the end, so this intentionally demonstrates a deep-page case rather than all pagination workloads.
- Indexes improve some reads but add storage and write/maintenance work; this benchmark does not measure insert cost yet.
- Query latency is affected by the operating system, storage, SQLite version, and cache state. Repeat runs and compare the shape rather than one number.
