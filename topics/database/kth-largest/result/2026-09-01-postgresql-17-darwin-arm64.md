# Finding the x-th largest results

These are local observations for the x-th-largest experiment. They show the shape of work on one machine, not universal performance ratios.

## Environment

- Date: 2026-09-01
- Host: Darwin arm64
- Docker client and server: 29.6.2
- PostgreSQL: 17.6 (`postgres:17.6-alpine`)
- Storage: Docker `tmpfs`
- Command: `./run.sh 1000000`
- Measurement: `EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF)` where applicable

## Observations

The table contains one million rows but only 10,000 score values. The covering index is `(score DESC, id ASC)`.

| Request | Index entries consumed | Shared buffers | Execution time |
| --- | ---: | ---: | ---: |
| 100th row | 100 | 4 | 0.015 ms |
| 100,000th row | 100,000 | 387 | 3.991 ms |
| 900,000th row | 900,000 | 3,452 | 34.778 ms |
| 1,000th distinct score | 99,901 | 386 | 4.422 ms |
| Precomputed rank 900,000 | 1 | 4 | 0.010 ms |

The B-tree removed sorting but did not make arbitrary rank lookup logarithmic. `Limit` still consumed approximately x index entries for the x-th row. The distinct-score case consumed all duplicate entries encountered before PostgreSQL produced 1,000 unique values.

Materializing every `row_number()` scanned all one million index entries and took 309.278 ms for the `WindowAgg` and table creation portion. The resulting table and rank index used 71 MB. Subsequent rank lookup became a normal primary-key point query, trading refresh work, storage, and freshness for predictable reads.

## Caveats

- `tmpfs` and a warm, idle database do not reproduce production storage, cache pressure, replicas, or concurrency.
- Materialized rank cost changes with update frequency and freshness requirements. Maintaining exact ranks under frequent score changes can move substantial work to the write path.
- The observed index-only scans depend on visibility-map state; active writes can introduce heap fetches.
