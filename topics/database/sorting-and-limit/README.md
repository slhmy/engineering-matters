# Sorting and `LIMIT`

An activity service shows one tenant's newest events. The first page asks for 50 rows, while an export uses the same order and may return every event for that tenant. Both queries contain `ORDER BY` and `LIMIT`, but PostgreSQL can do very different amounts of work depending on the limit and whether an index already stores rows in the required order.

## Mental Model

Without a matching index, PostgreSQL must find all qualifying rows before it knows which rows come first. A small limit can keep only the best N rows seen so far with a top-N heap, but it still reads every qualifying input row. A large limit can make sorting the complete candidate set cheaper than maintaining that heap.

With a matching B-tree, ordering work happened when the index was built and is maintained by writes. A query can seek to one tenant's ordered range, emit entries in order, and stop as soon as `LIMIT` is satisfied:

```text
without matching index: scan candidates -> sort or retain best N -> return N
with matching index:    seek ordered range -> return N -> stop
```

The second path does not make a large response free. It still reads and returns N index entries, and at sufficiently large N a sequential scan plus sort can become competitive because sequential access is cheap and indexes have storage and write costs.

## Experiment

The runnable PostgreSQL 17.6 experiment is in [`benchmark/`](benchmark/). It creates deterministic events distributed evenly across ten tenants. Timestamps repeat, so `id DESC` is a required unique tie-breaker rather than decoration.

Run the exact matrix with:

```bash
cd topics/database/sorting-and-limit/benchmark
./run.sh 100000
./run.sh 1000000
docker compose down
```

The Compose project is `sorting-and-limit`, the database is `sorting_and_limit`, and PostgreSQL is exposed only on `127.0.0.1:15439`. Database storage is temporary `tmpfs` storage.

Each measured query gets one warmup and then uses `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)`. The main matrix does not disable scan types or otherwise force plans:

| Rows | Candidate index | Limit | Intended question |
| ---: | --- | ---: | --- |
| 100,000 and 1,000,000 | None matching the filter and order | 50 | Does a small limit reduce sorting memory but not scan work? |
| 100,000 and 1,000,000 | None matching the filter and order | rows / 10 | Does returning the tenant's complete set produce a full sort? |
| 100,000 and 1,000,000 | `(tenant_id, created_at DESC, id DESC)` | 50 | Can an ordered index stop after 50 entries? |
| 100,000 and 1,000,000 | Same matching index | rows / 10 | How does index work grow with returned rows? |

The selected columns remain exactly `id, created_at` in all cases. They are present in the matching index, so changing payload width does not silently change one case's projection. A local run is recorded in [`result/2026-09-02-postgresql-17-darwin-arm64.md`](result/2026-09-02-postgresql-17-darwin-arm64.md).

## Experiment And Result Interpretation

| Change | Observe | Interpretation |
| --- | --- | --- |
| No index, reduce the limit from the full tenant set to 50 | PostgreSQL uses top-N heapsort, but the sequential scan still examines the whole table. | `LIMIT` bounds retained sort state; it does not let an unordered scan know which unseen row might rank first. |
| No index, request every qualifying row | PostgreSQL uses a full sort rather than top-N heapsort. | When N approaches the candidate count, all qualifying tuples must be retained and ordered. Memory limits can turn this into an external merge using temporary storage. |
| Add the matching composite index with `LIMIT 50` | The sort disappears and the index-only scan emits only 50 rows. | Equality on the leading tenant column creates one range whose remaining key order exactly matches the query, allowing early stop. |
| Keep the index but use the large limit | The index-only scan emits 10,000 or 100,000 rows and visits correspondingly more buffers. | An index removes the explicit sort, not the cost of consuming and returning a large result. The advantage over scan-and-sort narrows as N grows. |

The recorded run should be read primarily by plan shape, rows consumed, sort method, and buffers. Execution times are local observations on warm `tmpfs`, not portable ratios.

## Source And Pseudocode Walkthrough

The complete source is [`benchmark/sql/run.sql`](benchmark/sql/run.sql). Every case executes the same logical query and projection:

```sql
SELECT id, created_at
FROM events
WHERE tenant_id = 7
ORDER BY created_at DESC, id DESC
LIMIT :limit;
```

`created_at DESC` means newest timestamps first. Many generated rows share a timestamp, so `id DESC` gives tied rows one stable order. Without it, PostgreSQL may return tied rows in any order, and different plans need not choose the same 50 rows.

The matching index is:

```sql
CREATE INDEX events_tenant_timeline_idx
ON events (tenant_id, created_at DESC, id DESC);
```

Fixing `tenant_id = 7` leaves the index range ordered by exactly `(created_at DESC, id DESC)`. The small indexed case is conceptually:

```text
seek to the first index entry for tenant 7
repeat 50 times:
    emit id and created_at from the index
stop without examining the rest of tenant 7
```

Without that index, top-N heapsort is conceptually:

```text
for every table row:
    if tenant_id is 7:
        retain it if it belongs in the best 50 seen so far
sort the retained 50 into output order
return them
```

For the large limit, every tenth generated row qualifies and the limit equals that exact count. PostgreSQL therefore has to order and return the complete qualifying set. This controlled pair changes only N while preserving the data, filter, projection, and ordering.

## Detailed Explanation

`LIMIT` sits above its input plan. It can stop requesting tuples early only when the child can produce tuples in the required order. An unordered sequential scan cannot stop at 50 qualifying rows because a later row may have a newer timestamp. PostgreSQL's top-N heapsort reduces memory and comparison work relative to sorting all candidates, but it does not avoid the scan.

A full in-memory sort commonly reports `Sort Method: quicksort`. If the candidate tuples exceed `work_mem`, PostgreSQL can report `external merge` and temporary reads and writes. Top-N heapsort, quicksort, and external merge are execution strategies, not SQL guarantees; row width, N, estimates, `work_mem`, and concurrent memory pressure influence the choice.

The composite index addresses both filtering and ordering. Its leading equality key narrows work to tenant 7, while the two descending keys match the requested direction. PostgreSQL can scan a B-tree backward when all directions reverse together, but mixed directions must match an index's ordering capabilities. Writing both directions here makes the intended timeline order explicit.

The index-only plans are possible because both selected columns are in the index and `VACUUM` marks pages all-visible. Under active writes, heap fetches may appear. Selecting `payload` would also require heap access unless it were included in the index, which would make the index larger and more expensive to maintain.

For `LIMIT 50`, ordered access turns table-size work into a short range read in this distribution. For the large limit, it still consumes every tenant entry. If most of a table must be returned, a planner may prefer sequential access and sorting, especially when the projection requires heap pages anyway. Even when the index scan remains faster in this controlled run, its growing rows and buffers demonstrate why “no sort node” does not mean constant cost.

## Boundaries

- Results depend on candidate fraction, limit, row width, `work_mem`, cache state, storage, and concurrent load.
- This experiment has uniform tenants and deterministic timestamps. Hot tenants, skew, and correlation can change estimates and break-even points.
- The index supports this tenant-first timeline. A global timeline or a different mix of ascending and descending keys may need another index.
- Indexes move work to inserts, updates, WAL, storage, backups, and cache. Read speed is not the only cost.
- Index-only scans depend on the visibility map. Frequently updated tables may perform heap fetches.
- A large result also incurs serialization, network, and client processing that `EXPLAIN` does not measure because it discards result output.

## Common Misconceptions

- "`LIMIT 50` means PostgreSQL reads only 50 rows." Only an order-compatible access path can safely stop that early; an unordered scan still examines all possible candidates.
- "Top-N heapsort avoids sorting." It is a bounded sorting strategy. It retains fewer tuples but still compares candidates from the complete input.
- "An index on `created_at` is enough." For one tenant, a tenant-leading index creates the narrow ordered range. A global time index can interleave all tenants.
- "Tied timestamps are harmless." Without a unique tie-breaker, result order and page boundaries are not deterministic.
- "If the plan has no `Sort`, the query is cheap." A large ordered index scan can still consume many pages and return many rows.
- "The matching index is always best." Large result sets, non-covering projections, weak filtering, and write pressure can make scan-and-sort or no extra index the better tradeoff.
