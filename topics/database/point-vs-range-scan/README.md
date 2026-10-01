# Point lookup versus range scan

An API starts with `GET /records/:id`, which retrieves one row by primary key. Later, an export endpoint asks for every record between two IDs. Both predicates use the same indexed column, but "the query uses a B-tree" does not say how much work either request performs.

This topic compares a one-row point lookup with increasingly wide contiguous ranges. It isolates the important distinction: a B-tree can find the beginning of a range cheaply, but it cannot make the matching rows disappear or return them without reading them.

## Mental Model

Think of a sorted book index. Looking up one entry requires a short navigation to one page. Looking up a chapter range still lets you jump directly to the first page, but then you must read every requested page until the range ends.

The approximate work is:

```text
point lookup = B-tree seek + one matching tuple
range scan   = B-tree seek + matching index entries + matching heap tuples
```

The seek grows slowly as the tree grows. The second part grows with range cardinality. When a range covers enough of the table, PostgreSQL may decide that reading the table directly is cheaper than following many index entries to heap pages.

## Experiment

The experiment runs PostgreSQL 17.6 in Docker Compose. It creates either 100,000 or 1,000,000 rows and one B-tree, the primary-key index `records_pkey` on `id`.

Run the complete matrix with:

```bash
cd topics/database/point-vs-range-scan/benchmark
./run.sh 100000
./run.sh 1000000
docker compose down
```

The Compose project is explicitly named `point-vs-range-scan`, the database is `point_vs_range_scan`, and PostgreSQL is exposed on host port `15438`. Its data directory is a Docker `tmpfs`; no database volume remains after teardown.

Every measured query returns exactly `id, payload`, and every payload contains 64 ASCII bytes. The displayed plan width is therefore 73 bytes in this run. The table contents, starting key, and physical layout are deterministic. IDs are inserted in a modular permutation rather than sorted order so physical clustering does not give large ranges an accidental advantage.

The matrix changes requested cardinality while keeping the table, B-tree, projection, range start, cache warmup, and measurement form fixed:

| Case | Predicate cardinality at 100,000 | Predicate cardinality at 1,000,000 |
| --- | ---: | ---: |
| Point lookup | 1 | 1 |
| Fixed range | 100 | 100 |
| 1% range | 1,000 | 10,000 |
| 10% range | 10,000 | 100,000 |
| 50% range | 50,000 | 500,000 |

Each case first executes the identical `SELECT id, payload` query as a warmup, with client output redirected to `/dev/null`. The measured execution uses `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)`. Observe the scan node, `actual rows`, heap blocks, shared buffers, and execution time. No planner method is enabled or disabled in the main matrix.

One local run is recorded in [`result/2026-09-02-postgresql-17-darwin-arm64.md`](result/2026-09-02-postgresql-17-darwin-arm64.md). Treat its timings as local observations, not promises for another machine.

## Experiment And Result Interpretation

| Change | Local observation | Interpretation |
| --- | --- | --- |
| Grow the table while keeping a point result at one row | The point lookup used an `Index Scan`, returned one row, and touched 3 buffers at 100,000 rows and 4 at 1,000,000 rows. | B-tree height and a single heap fetch grow slowly compared with table cardinality. |
| Expand from one row to a 100-row contiguous range | PostgreSQL changed to a `Bitmap Heap Scan`; 100 matching rows occupied 100 heap blocks in both datasets. | Finding the first key is cheap, but scattered matching tuples still require heap work. |
| Expand to 1% and 10% | At one million rows, shared buffers rose from 7,977 for 10,000 rows to 9,430 for 100,000 rows; execution rose from 5.452 ms to 12.279 ms. | An index bounds the range, but it must enumerate the range and retrieve its tuples. More results mean more work even though the initial seek is unchanged. |
| Expand to 50% | PostgreSQL selected a `Seq Scan` at both table sizes, returned half the rows, and filtered out the other half. | Once many heap pages are needed, scanning the table can cost less than traversing the index and coordinating many heap visits. |

The transition is cost-based, not a fixed percentage rule. Here, randomized physical placement makes matching IDs spread across heap pages. An ordered or recently clustered table could retain an index scan for a wider range, while wider rows, colder storage, different cache settings, or concurrent work could move the transition in the other direction.

Actual rows explain cardinality work better than the phrase "uses the index." At one million rows, the point and 10% cases both begin with the same B-tree, but one emits 1 index entry and the other emits 100,000 before fetching 100,000 tuples. Buffer counts expose the pages involved; execution time is a local consequence of that work and the environment.

### Reading The Timings

Two comparisons carry most of the information here.

**The point lookup is nearly free to grow.** 0.020 ms at 100,000 rows and 0.034 ms at 1,000,000 rows, with 3 and 4 buffers. Ten times the table added one buffer and 0.014 ms. That extra buffer is the interesting part: it is what a deeper B-tree costs. One added level means one more page to descend, and the tree stays shallow because fanout is high — a few hundred keys per page, so even a billion-row table would only be a few levels deep. A point lookup on an indexed column is close to a constant in table size, and this is what that constant looks like at this scale.

**The range work is sublinear in rows, and the reason is that the ranges nest.** At one million rows: 7,977 buffers and 5.452 ms for 10,000 tuples, then 9,425 buffers and 12.279 ms for 100,000. Ten times the returned rows cost 1.2x the buffers and 2.3x the time. That is not a general law, and the heap-block counts show why. Both ranges start at the same key — the 1% case is a strict subset of the 10% case — so they are a nested pair, not two independent samples. The 10,000-tuple range fetched 7,948 distinct heap blocks, close to one block per tuple, which is the worst case for scattered access. Widening the range to 100,000 tuples added only 1,198 more blocks, to 9,146, because the extra tuples mostly landed in blocks the narrow range had already touched. Per returned row the cost therefore falls from about 0.55 µs to 0.12 µs, and that drop is a marginal-cost statement about these two nested ranges, not a rule about range scans in general.

Read the two table sizes next to each other and the cache effect becomes visible. The 1% query returns the same 1,000 tuples at both sizes: 0.589 ms and 968 buffers at 100,000 rows, 5.452 ms and 7,977 buffers at 1,000,000 rows — about 9x the time and 8x the buffers, or 5.6 µs versus 0.55 µs per returned row. The 10% query tells the same story in reverse: 1.562 ms for 10,000 tuples at the smaller size, 12.279 ms for the larger. Nothing about the query changed between the two scales. At 100,000 rows the 10% range touched 1,334 of the table's 1,334 blocks — every block — so nearly the whole heap was already in the working set and later tuples on the same page were nearly free. At 1,000,000 rows those same 10,000 tuples were spread across 7,948 of 13,334 blocks, and each landing was close to an independent page fetch. Range cost here is dominated by how many distinct pages the range reaches, which depends on clustering and on table size, not on the row count of the answer.

The 50% sequential scan is the case where time and work diverge most, and it is worth being careful with. At one million rows it read 13,334 heap blocks — every block — plus 554 reads, and took 29.372 ms. Compare it to the 100,000-row 50% scan: 1,334 blocks, 2.769 ms. Ten times the blocks and ten times the time, which is what a sequential scan should do, since it is the one plan whose cost scales with table size rather than with the requested range. That is exactly the property that makes it the correct choice for wide ranges and a poor one for narrow ranges; the plan is not "slower," it is doing a different job. It is also why the transition is a cost decision and not a percentage: the sequential scan's cost is fixed for a given table, so a larger table raises the bar that the index path has to beat.

Finally, note the two buffer lines at one million rows that include read counts: 5 reads on the 10% bitmap case and 554 on the 50% scan. The heap occupies 13,334 pages, about 104 MB, so it does not stay resident in shared buffers. Those reads are part of why the 100,000-row equivalents look disproportionately fast. Buffer counts in this experiment are partly a statement about cache residency, so compare plans at a fixed table size, and read absolute times across sizes with that in mind.

## Source And Pseudocode Walkthrough

The full source is [`benchmark/sql/run.sql`](benchmark/sql/run.sql). The table deliberately has one fixed-width logical result shape:

```sql
CREATE TABLE records (
    id bigint PRIMARY KEY,
    payload text NOT NULL
);

INSERT INTO records (id, payload)
SELECT (physical_position * 7919) % :rows::bigint + 1, repeat('x', 64)
FROM generate_series(1, :rows::bigint) AS physical_position;
```

For both supported row counts, multiplying by 7,919 modulo the row count visits every ID exactly once because 7,919 is coprime with 100,000 and 1,000,000. The resulting deterministic heap order has low correlation with `id`; the primary key still supplies the only B-tree used by every case.

The point query asks for one unique key:

```sql
SELECT id, payload
FROM records
WHERE id = :rows::bigint / 4;
```

Its conceptual path is:

```text
descend records_pkey to the target key
read the matching heap tuple
return one fixed-width result
```

Each range starts at that same key. Only its exclusive upper bound changes:

```sql
SELECT id, payload
FROM records
WHERE id >= :rows::bigint / 4
  AND id < :rows::bigint / 4 + :rows::bigint / 10;
```

An index range path is conceptually:

```text
descend records_pkey to the lower bound
while the next index key is below the upper bound:
    record or follow the tuple location
read the matching heap tuple
return the same fixed-width result
```

A bitmap plan separates collecting tuple locations from heap access, allowing PostgreSQL to visit heap pages more systematically. A sequential plan instead reads each table page once and tests the predicate. These plans implement the same SQL and return the same rows; the optimizer chooses among them from estimated total cost.

## Detailed Explanation

A B-tree's logarithmic lookup property describes navigation to a key, not the complete cost of producing an arbitrary result set. For a point predicate on a unique key, navigation dominates because only one index entry and heap tuple qualify. This is the familiar fast primary-key lookup.

For a range, the lower bound still provides a cheap navigation point. After that seek, leaf entries are ordered and contiguous in the index, but PostgreSQL must process every qualifying entry. Because PostgreSQL tables are heaps, those index entries refer to tuple locations in separate heap pages. In this experiment the deterministic permutation spreads nearby IDs through the heap, making that distinction visible.

The bitmap scans first build a bitmap from qualifying B-tree entries. They then fetch matching heap pages rather than bouncing between pages in raw index order. At 100,000 rows, the 1% case returned 1,000 rows from 963 heap blocks. The 10% case returned 10,000 rows and had already reached all 1,334 heap blocks. The B-tree still precisely identified matching tuples, but page coverage approached the whole table.

At 50%, PostgreSQL estimated that a sequential scan was cheaper. The plan read the table once, returned 50,000 or 500,000 rows, and rejected the same number. This is not an index failure. It is a rational transition when selectivity is low enough that the index's extra processing no longer saves sufficient heap work.

The experiment uses `TIMING OFF` to avoid per-node clock-reading overhead while retaining total execution time. Warmups reduce first-access noise, but they do not make the cache infinite: the one-million-row table and index can exceed PostgreSQL's shared-buffer residency. Buffer counts and plan shape are therefore the more transferable observations.

## Boundaries

- The physical layout is intentionally uncorrelated with `id`. `CLUSTER`, append-only ID order, and correlation between index and heap order can make range scans more sequential and keep index plans attractive longer.
- PostgreSQL may choose plain index, index-only, bitmap, parallel, or sequential plans under other schemas and settings. The crossover is not universally 50%.
- Selecting only indexed columns after a suitable `VACUUM` can permit an index-only scan. This experiment returns `payload` specifically to keep heap retrieval and result width constant.
- Wider rows increase table size and result processing. Narrower rows can change buffer counts and planner choices even at the same selectivity.
- `EXPLAIN ANALYZE` executes the query but does not send its rows to an application. Real exports also pay serialization, network, client memory, and backpressure costs.
- `tmpfs`, warm reads, one measured execution, and an idle database do not model durable storage, cold starts, concurrency, updates, bloat, or production cache pressure.
- The experiment measures reads only. Primary-key maintenance, WAL, checkpoints, and write amplification remain real B-tree costs.

## Common Misconceptions

- "A B-tree makes every range query logarithmic." Only finding a boundary is logarithmic; processing and returning `k` matches still requires work proportional to `k` and the pages containing them.
- "If PostgreSQL chooses a sequential scan, the index is broken." A sequential scan can be cheaper when a predicate requests much of the table.
- "An indexed predicate means few reads." An index can identify a large range precisely while that range still covers most heap pages.
- "The planner always switches at the same selectivity." Row width, physical correlation, statistics, cache costs, storage, concurrency, and selected columns all affect the crossover.
- "A fast `count(*)` proves returning the rows is equally fast." Aggregation has a different result width and may enable a different plan, so this matrix keeps the projected rows unchanged.
