# PostgreSQL table growth extension results

These are local observations for the UUID primary-key and x-th-largest experiments. They show the shape of work on one machine, not universal performance ratios.

## Environment

- Date: 2026-09-01
- Host: Darwin arm64
- Docker client and server: 29.6.2
- PostgreSQL: 17.6 (`postgres:17.6-alpine`)
- Storage: Docker `tmpfs`
- Commands: `./run.sh uuid-ids 1000000` and `./run.sh kth-largest 1000000`
- Measurement: `EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF)` where applicable

## UUID Primary Keys

All tables contain one million rows with the same 80-byte payload. UUID values were generated before the measured inserts.

| Primary key | Table size | PK index size | WAL bytes | Point-lookup buffers |
| --- | ---: | ---: | ---: | ---: |
| Sequential `bigint` | 120 MB | 21 MB | 210,095,086 | 4 |
| Ordered synthetic UUID | 128 MB | 30 MB | 227,270,767 | 4 |
| Random deterministic UUID | 128 MB | 38 MB | 241,481,278 | 4 |

The ordered UUID control isolates width: its table and primary-key index were larger than the `bigint` equivalents even though both arrived in increasing order. Random insertion increased the UUID primary-key index from 30 MB to 38 MB and generated more WAL in this run.

All three warm point lookups had the same B-tree cost estimate and visited four shared buffers. At this scale, with hot data on `tmpfs`, lookup latency did not reveal the storage and write-path differences.

The random UUID insert happened to have a lower elapsed time than the other two in this single fixed-order run. That is not evidence that random insertion is generally faster: cache state, background writes, checkpoints, and the shared source scan affect elapsed time. Relation size and WAL are the more stable observations here.

## Finding The X-th Largest Row

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

- Each write case ran once and in a fixed order. Repeat runs in randomized order before comparing elapsed insertion time.
- `tmpfs` and a warm, idle database do not reproduce production storage, cache pressure, replicas, or concurrency.
- The synthetic ordered UUID is only a control variable; it is not UUIDv7.
- UUID costs change with row width, fill factor, index count, write duration, and whether indexes fit in memory.
- Materialized rank cost changes with update frequency and freshness requirements. Maintaining exact ranks under frequent score changes can move substantial work to the write path.
