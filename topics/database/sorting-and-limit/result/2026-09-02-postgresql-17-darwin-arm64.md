# Sorting and `LIMIT` results

These are local observations from the sorting-and-limit experiment. They document plan shape and visited work on one machine, not universal latency ratios.

## Environment

- Date: 2026-09-02
- Host: Darwin arm64
- Docker client and server: 29.6.2
- PostgreSQL: 17.6 (`postgres:17.6-alpine`)
- Storage: Docker `tmpfs`
- Commands: `./run.sh 100000` and `./run.sh 1000000`
- Measurement: one warmup before each `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)`
- Planner configuration: defaults; no scan or sort plans were forced

## Observations

Tenant 7 contains exactly one tenth of the table. All cases selected only `id` and `created_at` and ordered by `created_at DESC, id DESC`.

| Rows | Candidate index | Limit | Plan and sort method | Rows entering sort or index entries emitted | Shared buffers | Execution time |
| ---: | --- | ---: | --- | ---: | ---: | ---: |
| 100,000 | None | 50 | Sequential scan, top-N heapsort | 10,000 | 1,725 | 2.560 ms |
| 100,000 | None | 10,000 | Sequential scan, quicksort | 10,000 | 1,725 | 3.271 ms |
| 100,000 | Matching composite index | 50 | Index-only scan, no sort | 50 | 5 | 0.012 ms |
| 100,000 | Matching composite index | 10,000 | Index-only scan, no sort | 10,000 | 54 | 0.480 ms |
| 1,000,000 | None | 50 | Parallel sequential scan, top-N heapsort, gather merge | 100,000 | 17,368 | 13.648 ms |
| 1,000,000 | None | 100,000 | Parallel sequential scan, quicksort, gather merge | 100,000 | 17,368 | 24.334 ms |
| 1,000,000 | Matching composite index | 50 | Index-only scan, no sort | 50 | 4 | 0.017 ms |
| 1,000,000 | Matching composite index | 100,000 | Index-only scan, no sort | 100,000 | 496 | 4.988 ms |

For the one-million-row parallel plans, the table reports the total qualifying rows across all three processes. `EXPLAIN` displayed `actual rows=33333 loops=3` on the parallel scan because actual rows are per-loop averages. The buffer total likewise includes the leader and workers.

The small no-index query retained only 50 tuples per sort and reported `Sort Method: top-N heapsort  Memory: 28kB` at both table sizes. It nevertheless examined every table row: 90,000 rows failed the filter at 100,000 rows, and a total of 900,000 failed across the three processes at one million rows.

The large no-index query returned every qualifying row. PostgreSQL switched to a full in-memory quicksort: 775 kB for 10,000 rows in the single-process run, and 3,064 kB, 2,010 kB, and 1,906 kB across the leader and two workers for 100,000 rows. This run did not spill; wider selected tuples, lower `work_mem`, or more candidates could produce an external merge and temporary I/O instead.

The matching `(tenant_id, created_at DESC, id DESC)` index removed the sort in both limit cases. With `LIMIT 50`, the index-only scan emitted exactly 50 entries and stopped after 4 or 5 buffers. With the large limit it emitted 10,000 or 100,000 entries and visited 54 or 496 buffers. Removing the sort did not make work independent of returned rows.

At one million rows, the large no-index plan recorded 14,578 shared hits, 2,790 reads, and 96 writes; the small plan recorded 14,386 hits and 2,982 reads. The table combines those categories into 17,368 shared buffers for a compact work comparison. The writes are incidental background-buffer activity observed during this local run, not writes performed by the read-only query's SQL semantics.

## Caveats

- These measurements used a warm, idle database on `tmpfs`; production storage, cache pressure, and concurrency can change both plans and timings.
- PostgreSQL chose parallel scan and sort at one million rows but not at 100,000. Parallel `actual rows` values and sort memory are reported per process.
- The large sort fit in memory here. The experiment exposes a full quicksort, not an external spill, and does not claim that every large limit spills.
- The matching plans were index-only because `VACUUM` populated the visibility map and the projection was covered. Active writes or selecting `payload` can add heap access.
- `EXPLAIN ANALYZE` discards normal result transmission, so the timings omit serialization, network, and client costs for 10,000 or 100,000 returned rows.
- Index build time, index storage, WAL, and write amplification are outside this read matrix.
