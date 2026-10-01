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

The runnable experiment is in [`benchmark/`](benchmark/). PostgreSQL 17.6 and MySQL 8.4.6 receive the same deterministic events for 1,000 tenants and seven statuses. Each case keeps only one candidate composite index so another index cannot hide the effect of column order.

Run it with:

```bash
cd topics/database/composite-index-order/benchmark
./run.sh 100000
./run.sh 1000000
./run-mysql.sh 100000
./run-mysql.sh 1000000
docker compose down
```

The matrix compares:

| Query | Index orders |
| --- | --- |
| One tenant's latest 50 events | `(tenant_id, created_at DESC, id DESC)` vs `(created_at DESC, id DESC, tenant_id)` |
| One tenant and one status, latest 10 events | `(tenant_id, status, created_at DESC, id DESC)` vs `(status, tenant_id, created_at DESC, id DESC)` |
| Count one tenant without a status condition | The same two equality-column orders |

For PostgreSQL, observe `Index Cond`, scan type, actual rows, shared buffers, and whether a sort appears. For MySQL, observe iterator type, lookup keys, actual rows entering filters, and whether sorting appears. Local runs are recorded for [PostgreSQL 17.6](result/2026-09-02-postgresql-17-darwin-arm64.md) and [MySQL 8.4.6](result/2026-09-02-mysql-8-darwin-arm64.md).

## Experiment And Result Interpretation

| Change | Observe | Interpretation |
| --- | --- | --- |
| Put `tenant_id` before time for a tenant feed | At one million rows, the query visited 4 buffers instead of 247, in 0.015 ms instead of 0.383 ms. | The tenant equality selects one contiguous B-tree range, already ordered by time, so PostgreSQL can stop after 50 entries. |
| Swap `tenant_id` and `status` while constraining both by equality | Both orders returned 10 rows with 4 buffers and no sort, in 0.013 ms and 0.021 ms. | For this query, both equality values identify the same narrow prefix and the time columns remain ordered. Raw column selectivity does not make one order universally better. |
| Remove the `status` condition | Tenant-first used an index-only scan with 8 buffers in 0.080 ms; status-first became a parallel sequential scan with 12,346 buffers in 10.009 ms. | An unconstrained leading column splits one tenant's entries across status ranges. Column order must account for queries that omit one of the equality conditions. |

Interpret column order against the whole query portfolio. The best index for one fully constrained query can be a poor index for a related prefix query.

### Reading The Timings

The tenant feed is the case with a clean answer, and the timings agree with the buffers, which is not always true in these experiments. Tenant-first returns 50 rows in 0.015 ms from 4 buffers; time-first returns the same 50 rows in 0.383 ms from 247 buffers. That is roughly 25x the time for 60x the buffers, and both plans are index-only scans with no sort, so the entire difference is the walk. The tenant-first plan seeks to one tenant's range and takes the first 50 entries. The time-first plan has to scan the globally time-ordered index and test every entry for `tenant_id = 500`, stopping once it has accumulated 50 matches.

An important caution about the 247-buffer figure, and the reason it should not be read as a scalability result: it is the same 247 at 100,000 rows and at 1,000,000 rows, and the time moves only from 0.362 ms to 0.383 ms. That flatness does not mean the time-first index is immune to growth. It is an artifact of the controlled distribution, where tenant IDs repeat every 1,000 rows, so a fixed `LIMIT 50` always finds its matches within the same ~49,500-entry window regardless of how large the table is behind it. The cost of this plan scales with how far you must walk to accumulate 50 matches, which is a function of tenant sparsity and of the limit — not of table size directly. A partition of one tenant per 10,000 rows, or a `LIMIT 500`, would extend the walk proportionally.

The two equality cases measure a genuine tie and should be presented as one. 0.013 ms versus 0.021 ms, both from 4 buffers, is an 8 µs difference on a sub-100 µs measurement — scheduling noise, not a ranking. What the pair establishes is that when both leading columns are constrained by equality, the planner can use them as a narrow prefix in either order, so the extra time columns in the index still supply the required order for free. The lesson is negative but useful: "most selective column first" is not a rule that this query can distinguish, because both columns are fully pinned.

The count query is where the portfolio argument becomes concrete, and it is the only case in the experiment with a large timing gap. Tenant-first answers with an index-only scan over one tenant's entries: 8 buffers, 0.080 ms. Status-first cannot use `tenant_id` as a prefix at all, so it falls back to a parallel sequential scan touching all 12,346 buffers in 10.009 ms — roughly 125x the time. This is the same index, the same table, and the same predicate; only the position of `tenant_id` in the composite key differs. Read that number as the cost of an index that does not cover the leading predicate of a query you actually run, and it is why the case is in the matrix at all. It also explains the 100,000-row comparison in the source data: the same scan visited 1,235 buffers there, and the plan was chosen independently at both sizes rather than crossing over.

### Engine Comparison

The broad principles matched, but the optimizers exposed different fallback paths:

| Query and index | PostgreSQL 17.6 | MySQL 8.4.6 |
| --- | --- | --- |
| Tenant feed, tenant first | Index-only scan over one tenant range; 4 buffers | Covering index lookup; 50 entries returned |
| Tenant feed, time first | Index-only scan with a later-column `Index Cond`; 247 buffers | Covering index scan of 49,501 entries, then filter to 50 |
| Tenant + status, either equality order | Tight index-only scan; 4 buffers | Tight covering index lookup; 10 entries returned |
| Tenant count, status first | Parallel sequential scan of one million rows | Covering index skip scan returning 1,000 tenant entries |

MySQL's skip scan repeatedly probes the index for each distinct value of the missing leading `status` column. It is attractive here because `status` has only seven values. If the missing prefix had high cardinality, repeated probes could become expensive and the optimizer could choose another plan.

The MySQL timings show the same shape as PostgreSQL's, from a different mechanism:

| Case at 1,000,000 rows | Rows consumed | Execution time |
| --- | ---: | ---: |
| Tenant feed, tenant first | 50 | 0.015 ms |
| Tenant feed, time first | 49,501 | 4.73 ms |
| Tenant + status, tenant first | 10 | 0.015 ms |
| Tenant + status, status first | 10 | 0.012 ms |
| Tenant count, tenant first | 1,000 | 0.077 ms |
| Tenant count, status first | 1,000 (skip scan) | 0.165 ms |

Tenant-first costs about 0.3 µs per returned row while the time-first feed costs about 0.096 µs per *consumed* row — the per-row cost is lower, but there are 990 times as many rows to consume, so the total is 315x higher. That is the same conclusion as the PostgreSQL buffer comparison with a different unit of measurement. Note also that the time-first feed consumed 49,501 entries at both table sizes and its time barely moved, 4.65 ms to 4.73 ms, for the same distribution reason described above.

The count query is where the two engines differ in character rather than degree. PostgreSQL abandoned the index entirely for a parallel sequential scan, 10.009 ms; MySQL kept a covering skip scan for 0.165 ms. The buffer-versus-iterator comparison is not meaningful across engines, but the fact that one optimizer found an index path and the other did not is, and it is a reminder that "the index cannot be used for this predicate" is an engine-specific statement.

Do not compare PostgreSQL buffer counts directly with MySQL iterator row counts, or use these timings to rank engines. Their storage structures, caches, instrumentation, and container processes differ. Compare how each plan's work changes when column order or row count changes within the same engine.

## Source And Pseudocode Walkthrough

The PostgreSQL source is [`benchmark/sql/run.sql`](benchmark/sql/run.sql), and the equivalent MySQL source is [`benchmark/sql/mysql.sql`](benchmark/sql/mysql.sql). The first comparison keeps the query fixed:

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

With time first, the index provides the requested global time order, but one tenant's rows are interleaved with other tenants. PostgreSQL still displays `tenant_id` as an `Index Cond`; MySQL displays a covering index scan followed by a filter. Neither engine gets the same tight tenant range. This is why "a later column can never be used" is too strong even though the leading order still controls scan efficiency.

The equality-order comparison uses:

```sql
WHERE tenant_id = :tenant_id AND status = :status
ORDER BY created_at DESC, id DESC
```

Both `(tenant_id, status, created_at, id)` and `(status, tenant_id, created_at, id)` group the requested pair contiguously. Once `status = :status` is removed, only the tenant-first index retains a direct tenant prefix. The source makes the decision rule concrete: arrange equality prefixes around the combinations queries actually provide, then place range and ordering columns where they preserve the required scan order.

## Detailed Explanation

For a B-tree, equality on leading columns narrows the scan to one prefix. The first range or unconstrained column usually determines how much of the index must be traversed; conditions on later columns may still be checked by the index or reduce heap access, but they do not necessarily reduce the scanned index region as effectively.

`ORDER BY` changes the decision. An index can avoid sorting only when its ordering is compatible after accounting for fixed equality columns. In `(tenant_id, created_at DESC, id DESC)`, fixing one tenant leaves entries ordered exactly as the feed needs. A unique `id` tie-breaker makes pagination and result order deterministic.

Both engines choose plans by estimated cost, not by a binary leftmost-prefix rule. PostgreSQL 17 chose a broad index path for the time-first feed and a sequential scan for the missing-status tenant count. MySQL 8.4 made the broad time-first scan explicit, but used skip scan when only seven leading status values had to be enumerated. Use `EXPLAIN (ANALYZE, BUFFERS)` in PostgreSQL and `EXPLAIN ANALYZE` in MySQL to identify the actual fallback.

The phrase "covering index" also hides an engine difference. PostgreSQL index entries point to heap tuples, and an index-only scan still depends on the visibility map. InnoDB secondary-index leaves contain the primary-key value and can satisfy these selected columns from the index. That implementation difference is another reason to compare plan shape rather than raw cross-engine timing.

## Boundaries

- Do not choose index order from per-column selectivity alone. Equality combinations, ranges, ordering, grouping, and omitted predicates all matter.
- More indexes can support more query shapes, but every index consumes storage, WAL, cache, and write maintenance.
- This experiment uses uniform tenants. Hot tenants, sparse tenants, correlated columns, and stale statistics can change planner estimates and useful order.
- Skip scan availability and costing depend on database engine and version; it should not be assumed from generic B-tree theory alone.
- `IN`, multiple ranges, nullable columns, mixed sort directions, and partial indexes deserve separate experiments.
- Index-only scans rely on visibility-map state. Active updates can add heap fetches even with the same column order.

## Common Misconceptions

- "Columns after the first missing predicate are never used." They may still be checked in the index; the tighter claim is that they often cannot define one narrow contiguous range.
- "Put the most selective column first." This ignores which predicates are equalities, which queries omit columns, and which order the result needs.
- "If an index removes sorting, it must be efficient." A time-first index can emit the right order while scanning many unrelated tenants before reaching the limit.
- "One wide index replaces all shorter indexes." A wide index helps only where its prefixes and ordering match real access patterns.
