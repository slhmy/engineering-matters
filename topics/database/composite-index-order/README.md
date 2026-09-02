# Composite index column order

A multi-tenant event service often needs both a recent activity feed for one tenant and filtered operational reports. All required columns may appear in an index, yet changing their order can turn a short B-tree seek into a broad scan.

This topic uses "composite index" for an index containing multiple columns. It is also commonly called a multi-column or compound index. It is different from an aggregate query and from a clustered table layout.

## Mental Model

A B-tree on `(a, b, c)` is sorted lexicographically:

```text
first by a
  then by b inside each a
    then by c inside each (a, b)
```

The useful question is not only "does the index contain this column?" It is "does the query describe a narrow, contiguous range in this ordering, and does the remaining order match `ORDER BY`?"

## Experiment

The runnable PostgreSQL experiment is in [`benchmark/`](benchmark/). It creates deterministic events for 1,000 tenants and seven statuses, then ensures only one candidate composite index exists for each case.

Run it with:

```bash
cd topics/database/composite-index-order/benchmark
./run.sh 100000
./run.sh 1000000
docker compose down
```

The matrix compares:

| Query | Index orders |
| --- | --- |
| One tenant's latest 50 events | `(tenant_id, created_at DESC, id DESC)` vs `(created_at DESC, id DESC, tenant_id)` |
| One tenant and one status, latest 10 events | `(tenant_id, status, created_at DESC, id DESC)` vs `(status, tenant_id, created_at DESC, id DESC)` |
| Count one tenant without a status condition | The same two equality-column orders |

Observe `Index Cond`, scan type, actual rows, buffers, and whether a sort appears. One local run is recorded in [`result/2026-09-02-postgresql-17-darwin-arm64.md`](result/2026-09-02-postgresql-17-darwin-arm64.md).

## Experiment And Result Interpretation

| Change | Observe | Interpretation |
| --- | --- | --- |
| Put `tenant_id` before time for a tenant feed | At one million rows, the query visited 4 buffers instead of 247. | The tenant equality selects one contiguous B-tree range, already ordered by time, so PostgreSQL can stop after 50 entries. |
| Swap `tenant_id` and `status` while constraining both by equality | Both orders returned 10 rows with 4 buffers and no sort. | For this query, both equality values identify the same narrow prefix and the time columns remain ordered. Raw column selectivity does not make one order universally better. |
| Remove the `status` condition | Tenant-first used an index-only scan with 8 buffers; status-first became a parallel sequential scan with 12,346 buffers. | An unconstrained leading column splits one tenant's entries across status ranges. Column order must account for queries that omit one of the equality conditions. |

Interpret column order against the whole query portfolio. The best index for one fully constrained query can be a poor index for a related prefix query.

## Source And Pseudocode Walkthrough

The complete experiment is [`benchmark/sql/run.sql`](benchmark/sql/run.sql). The first comparison keeps the query fixed:

```sql
SELECT id, created_at
FROM events
WHERE tenant_id = :tenant_id
ORDER BY created_at DESC, id DESC
LIMIT 50;
```

Only the index order changes:

```sql
CREATE INDEX ON events (tenant_id, created_at DESC, id DESC);
CREATE INDEX ON events (created_at DESC, id DESC, tenant_id);
```

With tenant first, the conceptual path is:

```text
seek to tenant_id
read the first 50 entries in descending time order
stop
```

With time first, the index provides the requested global time order, but one tenant's rows are interleaved with other tenants. PostgreSQL can still apply `tenant_id` inside an index scan; it simply cannot describe the same tight tenant range. This is why "a later column can never be used" is too strong even though the leading order still controls scan efficiency.

The equality-order comparison uses:

```sql
WHERE tenant_id = :tenant_id AND status = :status
ORDER BY created_at DESC, id DESC
```

Both `(tenant_id, status, created_at, id)` and `(status, tenant_id, created_at, id)` group the requested pair contiguously. Once `status = :status` is removed, only the tenant-first index retains a direct tenant prefix. The source makes the decision rule concrete: arrange equality prefixes around the combinations queries actually provide, then place range and ordering columns where they preserve the required scan order.

## Detailed Explanation

For a B-tree, equality on leading columns narrows the scan to one prefix. The first range or unconstrained column usually determines how much of the index must be traversed; conditions on later columns may still be checked by the index or reduce heap access, but they do not necessarily reduce the scanned index region as effectively.

`ORDER BY` changes the decision. An index can avoid sorting only when its ordering is compatible after accounting for fixed equality columns. In `(tenant_id, created_at DESC, id DESC)`, fixing one tenant leaves entries ordered exactly as the feed needs. A unique `id` tie-breaker makes pagination and result order deterministic.

PostgreSQL chooses plans by estimated cost, not by a binary leftmost-prefix rule. Depending on distribution and version, it may use a later-column condition in an index scan, use skip-scan-like repeated searches, scan a broad part of an index, or prefer a sequential scan. `EXPLAIN (ANALYZE, BUFFERS)` reveals which behavior occurred.

## Boundaries

- Do not choose index order from per-column selectivity alone. Equality combinations, ranges, ordering, grouping, and omitted predicates all matter.
- More indexes can support more query shapes, but every index consumes storage, WAL, cache, and write maintenance.
- This experiment uses uniform tenants. Hot tenants, sparse tenants, correlated columns, and stale statistics can change planner estimates and useful order.
- `IN`, multiple ranges, nullable columns, mixed sort directions, and partial indexes deserve separate experiments.
- Index-only scans rely on visibility-map state. Active updates can add heap fetches even with the same column order.

## Common Misconceptions

- "Columns after the first missing predicate are never used." They may still be checked in the index; the tighter claim is that they often cannot define one narrow contiguous range.
- "Put the most selective column first." This ignores which predicates are equalities, which queries omit columns, and which order the result needs.
- "If an index removes sorting, it must be efficient." A time-first index can emit the right order while scanning many unrelated tenants before reaching the limit.
- "One wide index replaces all shorter indexes." A wide index helps only where its prefixes and ordering match real access patterns.
