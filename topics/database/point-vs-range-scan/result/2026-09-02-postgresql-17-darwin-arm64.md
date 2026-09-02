# Point lookup versus range scan results

These are local observations from one foundational PostgreSQL run. They document plan transitions and visited work, not universal latency thresholds.

## Environment

- Date: 2026-09-02
- Host: Darwin arm64
- Docker client and server: 29.6.2
- PostgreSQL: 17.6 (`postgres:17.6-alpine`)
- Database: `point_vs_range_scan`
- Compose project: `point-vs-range-scan`
- Storage: Docker `tmpfs`
- Commands: `./run.sh 100000` and `./run.sh 1000000`
- Measurement: one identical-query warmup followed by `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)`
- Projection: `id, payload`; plan width 73 bytes in every case

## Observations

| Table rows | Requested rows | Plan | Actual rows | Heap blocks | Shared buffers | Execution time |
| ---: | ---: | --- | ---: | ---: | --- | ---: |
| 100,000 | 1 | Index Scan | 1 | 1 implicit heap visit | hit=3 | 0.020 ms |
| 100,000 | 100 | Bitmap Heap Scan | 100 | exact=100 | hit=102 | 0.102 ms |
| 100,000 | 1,000 (1%) | Bitmap Heap Scan | 1,000 | exact=963 | hit=968 | 0.589 ms |
| 100,000 | 10,000 (10%) | Bitmap Heap Scan | 10,000 | exact=1,334 | hit=1,365 | 1.562 ms |
| 100,000 | 50,000 (50%) | Seq Scan | 50,000; 50,000 removed | all 1,334 table blocks | hit=1,334 | 2.769 ms |
| 1,000,000 | 1 | Index Scan | 1 | 1 implicit heap visit | hit=4 | 0.034 ms |
| 1,000,000 | 100 | Bitmap Heap Scan | 100 | exact=100 | hit=103 | 0.132 ms |
| 1,000,000 | 10,000 (1%) | Bitmap Heap Scan | 10,000 | exact=7,948 | hit=7,977 | 5.452 ms |
| 1,000,000 | 100,000 (10%) | Bitmap Heap Scan | 100,000 | exact=9,146 | hit=9,425, read=5 | 12.279 ms |
| 1,000,000 | 500,000 (50%) | Seq Scan | 500,000; 500,000 removed | all 13,334 table blocks | hit=12,780, read=554 | 29.372 ms |

The point query stayed an `Index Scan`: the same primary-key B-tree found one key and PostgreSQL fetched one tuple. Growing the table by ten times added one shared buffer to this local path, rather than multiplying the work by ten.

Ranges of 100 through 10% used a `Bitmap Index Scan` on `records_pkey` followed by a `Bitmap Heap Scan`. The B-tree supplied exact lower and upper bounds, but the index node still emitted every matching tuple location. Heap blocks increased as nearby logical IDs mapped to scattered physical tuples.

At 50%, PostgreSQL independently chose a sequential scan for both table sizes. No planner choice was forced. Each scan visited every table block, returned half the rows, and removed half by the filter. Under this data layout, avoiding bitmap construction and index traversal cost less than using the B-tree for so many tuples.

## Caveats

- IDs were inserted with a deterministic modular permutation. This controls low physical correlation with the B-tree but does not represent an append-ordered or clustered table.
- The database was warm, idle, and on `tmpfs`. At one million rows, some shared reads remained because the full working set did not stay in PostgreSQL shared buffers; the underlying files were still memory-backed.
- Execution time is one measured execution after one warmup. Plan shape, actual rows, and buffers are more useful than small timing differences.
- The selected `payload` forces heap access and holds logical result width constant. A covering projection, wider payload, compression behavior, or toasted values would produce a different crossover.
- The measured `EXPLAIN ANALYZE` execution does not include sending all result rows over an application network connection.
- Default PostgreSQL planner settings were retained. Cost parameters, memory, parallelism, statistics, and host capacity can change plan selection.
