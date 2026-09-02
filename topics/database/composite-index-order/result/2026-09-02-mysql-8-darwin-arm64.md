# MySQL composite index column order results

These are local observations from the first MySQL run. They document iterator shape and visited rows, not universal latency ratios or a speed comparison with PostgreSQL.

## Environment

- Date: 2026-09-02
- Host: Darwin arm64
- Docker client and server: 29.6.2
- MySQL: 8.4.6 (`mysql:8.4.6`)
- Storage: Docker `tmpfs`
- Commands: `./run-mysql.sh 100000` and `./run-mysql.sh 1000000`
- Measurement: one warmup followed by `EXPLAIN ANALYZE`

## Observations

| Rows | Query and index | Main iterator | Rows consumed by main scan | Execution time |
| ---: | --- | --- | ---: | ---: |
| 100,000 | Tenant feed, tenant first | Covering index lookup | 50 | 0.010 ms |
| 100,000 | Tenant feed, time first | Covering index scan + filter | 49,501 | 4.65 ms |
| 1,000,000 | Tenant feed, tenant first | Covering index lookup | 50 | 0.015 ms |
| 1,000,000 | Tenant feed, time first | Covering index scan + filter | 49,501 | 4.73 ms |
| 1,000,000 | Tenant + status, tenant first | Covering index lookup | 10 | 0.015 ms |
| 1,000,000 | Tenant + status, status first | Covering index lookup | 10 | 0.012 ms |
| 1,000,000 | Tenant count, tenant first | Covering index lookup | 1,000 | 0.077 ms |
| 1,000,000 | Tenant count, status first | Covering index skip scan | 1,000 | 0.165 ms |

For the time-first feed, MySQL walked the global time-ordered index and evaluated `tenant_id = 500` until it found 50 matches. Because tenant 500 appears once per 1,000 generated rows, the iterator consumed 49,501 entries. The count stayed the same when the table grew because the distribution and `LIMIT 50` stayed fixed; it would grow for a sparser tenant or a larger limit.

When both tenant and status were equalities, MySQL used a covering index lookup for either equality-column order. Removing status from the status-first index did not force a table scan in this run. MySQL used a covering index skip scan: it enumerated the small set of leading status values and searched each corresponding tenant range.

The skip scan result is conditional, not a replacement for deliberate index order. `status` has only seven values, the selected columns are covered, and the data is warm. A high-cardinality missing prefix, selected non-index columns, different statistics, or other cost settings can lead to broader scans or a table scan.

## PostgreSQL Contrast

PostgreSQL 17 used a parallel sequential scan for the same status-first tenant count, while MySQL 8.4 chose skip scan. For the time-first feed, PostgreSQL printed the later tenant condition as an `Index Cond`; MySQL showed the work more explicitly as 49,501 index rows entering a filter.

These labels are engine-specific. PostgreSQL shared buffers and MySQL iterator rows measure different things, and InnoDB secondary indexes have different leaf contents from PostgreSQL indexes. Use the comparison to understand optimizer choices, not to infer that one database is globally faster.

## Caveats

- MySQL and PostgreSQL ran in separate containers with default settings; elapsed times are not controlled cross-engine benchmarks.
- The reads were warm, idle, and backed by `tmpfs`.
- The experiment keeps only one candidate composite index in each case.
- Uniform tenant and status distributions make skip scan unusually easy to reason about.
- The benchmark does not measure writes, index build cost, buffer-pool pressure, or non-covering lookups.
