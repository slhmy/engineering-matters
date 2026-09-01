# PostgreSQL table growth results

These are local observations from the first PostgreSQL run. They document a reproducible plan shape, not universal latency numbers.

## Environment

- Date: 2026-09-01
- Host: Darwin arm64
- Docker client and server: 29.6.2
- PostgreSQL: 17.6 (`postgres:17.6-alpine`)
- Storage: Docker `tmpfs`
- Commands: `./run.sh 100000` and `./run.sh 1000000`
- Measurement: one warmup followed by `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)`

## Observations

| Rows | Case | Execution time | Actual rows visited | Shared buffers |
| ---: | --- | ---: | ---: | ---: |
| 100,000 | Lookup, no index | 1.933 ms | 100,000 | 1,725 |
| 100,000 | Lookup, indexed | 0.100 ms | 100 index entries, 100 heap rows | 102 |
| 100,000 | Deep `OFFSET` | 3.401 ms | 99,050 index entries | 383 |
| 100,000 | Cursor | 0.019 ms | 50 index entries | 4 |
| 1,000,000 | Lookup, no index | 25.454 ms | 1,000,000 across 3 processes | 17,242 |
| 1,000,000 | Lookup, indexed | 0.171 ms | 100 index entries, 100 heap rows | 103 |
| 1,000,000 | Deep `OFFSET` | 35.948 ms | 999,050 index entries | 3,831 |
| 1,000,000 | Cursor | 0.014 ms | 50 index entries | 4 |

The 100,000-row lookup used a `Seq Scan`. At 1,000,000 rows PostgreSQL chose a `Gather` over a `Parallel Seq Scan` with two workers, showing that table growth can change the execution strategy rather than only making the same plan slower.

The indexed lookup used a `Bitmap Index Scan` followed by a `Bitmap Heap Scan` at both sizes. The query returned 100 rows and touched about 100 heap blocks, so its visited buffers did not grow with the total row count in this data distribution.

Both pagination cases used `orders_created_at_id_idx` as an index-only scan with zero heap fetches. The deep `OFFSET` scan produced almost every preceding index entry before `Limit` returned 50 rows. The cursor's row comparison became an `Index Cond`, allowing PostgreSQL to start near the requested key and produce only 50 entries.

## Caveats

- The database was warm, idle, and stored on `tmpfs`; this does not represent production disk latency or concurrent load.
- Execution time is from one measured execution per case. Buffer counts and visited rows are more useful than small timing differences here.
- Parallel planning depends on PostgreSQL settings and available CPU. Another environment may use a non-parallel sequential scan.
- The cursor uses immutable, unique ordering through `(created_at, id)`. Real cursor APIs must encode both values and define behavior for deleted or newly inserted rows.
- Index creation time, write amplification, table bloat, checkpoints, network latency, and lock behavior are outside this experiment.
