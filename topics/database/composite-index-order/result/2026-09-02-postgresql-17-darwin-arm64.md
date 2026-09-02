# Composite index column order results

These are local observations from the first PostgreSQL run. They document plan shape and visited work, not universal latency ratios.

## Environment

- Date: 2026-09-02
- Host: Darwin arm64
- Docker client and server: 29.6.2
- PostgreSQL: 17.6 (`postgres:17.6-alpine`)
- Storage: Docker `tmpfs`
- Commands: `./run.sh 100000` and `./run.sh 1000000`
- Measurement: one warmup followed by `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)`

## Observations

| Rows | Query and index | Plan | Shared buffers | Execution time |
| ---: | --- | --- | ---: | ---: |
| 100,000 | Tenant feed, tenant first | Index-only scan | 4 | 0.016 ms |
| 100,000 | Tenant feed, time first | Index-only scan | 247 | 0.362 ms |
| 1,000,000 | Tenant feed, tenant first | Index-only scan | 4 | 0.015 ms |
| 1,000,000 | Tenant feed, time first | Index-only scan | 247 | 0.383 ms |
| 1,000,000 | Tenant + status, tenant first | Index-only scan | 4 | 0.013 ms |
| 1,000,000 | Tenant + status, status first | Index-only scan | 4 | 0.021 ms |
| 1,000,000 | Tenant count, tenant first | Index-only scan | 8 | 0.080 ms |
| 1,000,000 | Tenant count, status first | Parallel sequential scan | 12,346 | 10.009 ms |

The time-first tenant feed touched the same 247 buffers at both sizes because tenant IDs repeat every 1,000 rows and the query stops after finding 50 matches. This is a property of the controlled distribution and limit, not evidence that its cost is independent of growth in general. A sparser tenant or larger limit would extend the scan.

PostgreSQL displayed `tenant_id = 500` as an `Index Cond` even when tenant was the third index column. The plan still visited substantially more index pages than the tenant-first range. The observation is more precise than saying the index was either "used" or "not used": both plans used an index, but they performed different amounts of work.

When both tenant and status were equalities, their order made little difference for that exact query. When status was omitted, the status-first index no longer provided a useful tenant prefix and PostgreSQL chose a parallel sequential scan. At 100,000 rows that scan visited 1,235 buffers; at one million it visited 12,346.

## Caveats

- Tenant and status distributions are deterministic and close to uniform. Real correlation and skew affect both useful ranges and planner estimates.
- The measured reads were warm and index-only on `tmpfs`; production heap fetches and storage latency can amplify differences.
- Each case had only one candidate composite index. A production schema may allow bitmap combinations or another index to win.
- The experiment measures reads, not index build time, write amplification, or cache competition among multiple indexes.
