# Table growth: write, width, archiving, and concurrency results

These are local observations from four additional experiments on the same generated `orders`-like schema. They document work performed, not universal thresholds. The read-only run from the first session is recorded separately in [`2026-09-01-postgresql-17-darwin-arm64.md`](2026-09-01-postgresql-17-darwin-arm64.md).

## Environment

- Date: 2026-09-19
- Host: Apple M4, 10 logical CPUs
- OS: macOS 26.5.1, Darwin arm64
- Docker client and server: 29.8.0
- PostgreSQL: 17.6 (`postgres:17.6-alpine`)
- Storage: Docker `tmpfs`
- Measurement: `EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF)` for statements; `pgbench` for concurrency

## Experiment A: Write path and index maintenance

Command:

```bash
./run-writes.sh 1000000 100000
```

### Insert 100,000 rows into empty tables

| Secondary indexes | Execution time | WAL bytes | Shared buffers |
| ---: | ---: | ---: | --- |
| 0 | 88.452 ms | 19,007,620 | hit=302,347, read=1 |
| 1 | 105.049 ms | 19,780,324 | hit=302,655, read=1 |
| 3 | 194.471 ms | 32,856,724 | hit=701,330, read=3 |

Each secondary index adds an index insert per row plus additional WAL. Three indexes roughly doubled execution time and increased WAL by about 73% over the zero-index case.

### Append 100,000 rows to a table already holding 1,000,000 rows (one secondary index)

| Target | Execution time | WAL bytes | Shared buffers |
| --- | ---: | ---: | --- |
| Empty table (from the row above) | 105.049 ms | 19,780,324 | hit=302,655, read=1 |
| Table with 1,000,000 existing rows | 127.866 ms | 21,135,700 | hit=403,280 |

Appending to the large table cost about 22% more time and 7% more WAL than the same batch into an empty table, while visiting more shared buffers for the deeper B-tree and larger heap.

### Update 10,000 rows

| Updated column | Fillfactor | WAL bytes | Shared buffers | HOT updates |
| --- | ---: | ---: | --- | ---: |
| Unindexed `payload` | 100 | 3,130,188 | hit=82,511 | 0 of 10,000 |
| Unindexed `payload` | 80 | 1,080,000 | hit=22,858 | 10,000 of 10,000 |
| Indexed `customer_id` | 80 | 2,107,284 | hit=71,429 | 0 of 10,000 |

A non-indexed update can avoid index maintenance only when the new tuple version fits on the same page. Fillfactor 80 left that room and produced heap-only tuple updates, cutting WAL by about two thirds. Changing an indexed value cannot be heap-only, so its WAL approached the fillfactor-100 case even though free space existed.

### Final sizes

| Table | Rows | Heap bytes | Index bytes | Total bytes |
| --- | ---: | ---: | ---: | ---: |
| `insert_none` | 100,000 | 10,117,120 | 2,260,992 | 12,410,880 |
| `insert_one` | 100,000 | 10,117,120 | 2,416,640 | 12,566,528 |
| `insert_three` | 100,000 | 10,117,120 | 5,341,184 | 15,491,072 |
| `append_one` | 1,100,000 | 111,255,552 | 12,853,248 | 124,174,336 |

The one-index table adds about 156 kB of index storage over the primary key alone; the three-index table adds about 3.1 MB. Index storage and write maintenance grow with both index count and table size.

## Experiment B: Row width and TOAST

Command:

```bash
./run-toast.sh 50000
```

Both tables hold 50,000 rows. The narrow payload is 40 bytes inline; the wide payload is about 6,400 bytes stored externally (`SET STORAGE EXTERNAL`), above the roughly 2 kB TOAST threshold.

### Storage size

| Table | Heap bytes | Index bytes | TOAST bytes | Total bytes |
| --- | ---: | ---: | ---: | ---: |
| Narrow payload | 5,062,656 | 1,753,088 | 40,960 | 6,856,704 |
| Wide payload | 3,833,856 | 1,753,088 | 414,310,400 | 419,897,344 |

The wide table's main heap was slightly smaller because its large values live out of line, but its total footprint was about 61 times larger once TOAST storage is counted.

### Query buffers and time

| Query | Narrow table | Wide table |
| --- | --- | --- |
| `SELECT id, created_at` for 505 rows | 348 buffers, 1.204 ms | 332 buffers, 0.401 ms |
| `SELECT id, length(payload)` for 505 rows | 351 buffers, 0.236 ms | 2,352 buffers, 19.951 ms |
| `SELECT count(*), sum(length(payload))` full scan | 618 buffers, 4.154 ms | 200,468 buffers, 580.848 ms |

A projection that stays on the main heap behaves similarly for both tables because the wide values are not stored there. Touching the payload forces TOAST reads: the wide table needed about 6.7 times the buffers and 85 times the time for the same 505 rows, and the full scan read roughly 200,000 buffers.

## Experiment C: Hot and cold archiving

Command:

```bash
./run-archive.sh 1000000
```

One million rows span 2020, and `created_at >= 2020-12-01` selects 82,170 rows (8.22%): the hot slice.

### Index storage for the hot query

| Variant | `created_at` index bytes |
| --- | ---: |
| Full table, full index | 31,563,776 |
| Full table, partial index | 2,613,248 |
| Partitioned table, local indexes | 34,570,240 |

The partial index covers only the hot slice, so it is about 12 times smaller than the full index while still serving the same recent-activity predicate. Per-partition indexes on the partitioned table total slightly more than the single full index because each partition carries its own B-tree.

### Recent-activity query

| Variant | Plan | Shared buffers | Execution time |
| --- | --- | --- | ---: |
| Full table | Index-only scan on the full index | hit=1, read=3 | 0.026 ms |
| Full table, partial index | Index-only scan on the partial index | hit=1, read=3 | 0.019 ms |
| Partitioned table | Index-only scan on the December partition | hit=3, read=1 | 0.019 ms |

With a `LIMIT 100` and an ordered index, all three plans touch only a few buffers, so the immediate query looks the same. The difference is in what must be maintained, cached, and vacuumed: a 31.6 MB full index, a 2.6 MB partial index, or 12 partition-local indexes.

### Cold query spanning six months

The partitioned plan performed a `Parallel Append` over the six matching partitions, visiting 5,557 shared hits, 601 reads, and 516 writes in 15.044 ms. Partition pruning excluded the other six months, but a genuinely cold query still scans every matching partition because no index covers a full month efficiently at this selectivity.

## Experiment D: Concurrent readers and writers

Commands:

```bash
./run-concurrency.sh 100000
./run-concurrency.sh 1000000
```

`pgbench` ran for 5 s per case, with `--protocol=prepared`. Buffer columns are `heap_hit | heap_read | index_hit | index_read` after a per-case `pg_stat_reset()`.

### 100,000 rows (fits in shared buffers)

| Workload | Clients | TPS | Latency average | Heap buffers | Index buffers |
| --- | ---: | ---: | ---: | --- | --- |
| Point read | 1 | 26,968 | 0.037 ms | hit=134,811, read=0 | hit=269,624, read=0 |
| Point read | 8 | 129,922 | 0.062 ms | hit=649,274, read=0 | hit=1,298,564, read=0 |
| Point update | 1 | 24,847 | 0.040 ms | hit=374,291, read=0 | hit=248,418, read=0 |
| Point update | 8 | 90,012 | 0.089 ms | hit=1,349,491, read=0 | hit=899,640, read=0 |

### 1,000,000 rows (exceeds shared buffers)

| Workload | Clients | TPS | Latency average | Heap buffers | Index buffers |
| --- | ---: | ---: | ---: | --- | --- |
| Point read | 1 | 28,498 | 0.035 ms | hit=116,551, read=25,909 | hit=425,605, read=1,777 |
| Point read | 8 | 129,110 | 0.062 ms | hit=527,467, read=118,031 | hit=1,936,505, read=5 |
| Point update | 1 | 24,826 | 0.040 ms | hit=365,879, read=23,086 | hit=372,309, read=2 |
| Point update | 8 | 89,210 | 0.090 ms | hit=1,256,018, read=81,942 | hit=1,337,941, read=9 |

Growing from 100,000 to 1,000,000 rows introduced heap reads that did not occur when the table fit in the buffer cache: about 18% of point-read heap accesses were reads at both client counts. Throughput and average latency were nearly unchanged, because those reads came from `tmpfs` rather than a physical disk. Scaling from 1 to 8 clients raised both workloads by roughly 3.6 to 4.8 times without saturating.

## Caveats

- The database was warm, idle, and stored on `tmpfs`. Physical disk latency, checkpoints, and concurrent background maintenance would change the timing and read-cost results.
- Write timings are single measured statements. WAL bytes, buffer counts, and plan shape are more transferable than elapsed time.
- Index sizes depend on the key distribution. `customer_id` has only 100,000 distinct values over one million rows, so B-tree deduplication keeps that index small.
- `pgbench` used random point access with one read or one update per transaction. Real mixes include range scans, joins, and multi-statement transactions.
- The buffer counters are cumulative per case after `pg_stat_reset()` and include background activity from the same interval.
- The partial index covers a fixed hot boundary. A moving hot window needs a matching, maintained predicate.
- The wide-payload storage was forced to `EXTERNAL` to isolate out-of-line width from compression. Default `EXTENDED` storage would compress or store differently depending on the value.
