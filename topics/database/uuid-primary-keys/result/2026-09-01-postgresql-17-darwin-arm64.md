# UUID primary-key results

These are local observations for the UUID primary-key experiment. They show the shape of work on one machine, not universal performance ratios.

## Environment

- Date: 2026-09-01
- Host: Darwin arm64
- Docker client and server: 29.6.2
- PostgreSQL: 17.6 (`postgres:17.6-alpine`)
- Storage: Docker `tmpfs`
- Command: `./run.sh 1000000`
- Measurement: `EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF)`

## Observations

All tables contain one million rows with the same 80-byte payload. UUID values were generated before the measured inserts.

| Primary key | Table size | PK index size | WAL bytes | Point-lookup buffers |
| --- | ---: | ---: | ---: | ---: |
| Sequential `bigint` | 120 MB | 21 MB | 210,095,086 | 4 |
| Ordered synthetic UUID | 128 MB | 30 MB | 227,270,767 | 4 |
| Random deterministic UUID | 128 MB | 38 MB | 241,481,278 | 4 |

The ordered UUID control isolates width: its table and primary-key index were larger than the `bigint` equivalents even though both arrived in increasing order. Random insertion increased the UUID primary-key index from 30 MB to 38 MB and generated more WAL in this run.

All three warm point lookups had the same B-tree cost estimate and visited four shared buffers. At this scale, with hot data on `tmpfs`, lookup latency did not reveal the storage and write-path differences.

The random UUID insert happened to have a lower elapsed time than the other two in this single fixed-order run. That is not evidence that random insertion is generally faster: cache state, background writes, checkpoints, and the shared source scan affect elapsed time. Relation size and WAL are the more stable observations here.

## Caveats

- Each write case ran once and in a fixed order. Repeat runs in randomized order before comparing elapsed insertion time.
- `tmpfs` and a warm, idle database do not reproduce production storage, cache pressure, replicas, or concurrency.
- The synthetic ordered UUID is only a control variable; it is not UUIDv7.
- UUID costs change with row width, fill factor, index count, write duration, and whether indexes fit in memory.
