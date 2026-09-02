# Index selectivity and heap access

An operations service stores event details and filters them by a numeric classification. The classification already has a B-tree index, so it is tempting to expect every filter on that column to use the index. That expectation breaks when a predicate matches a large part of the table.

This topic holds the table, query shape, index, and data distribution fixed while changing only table size and the fraction of rows matched. It demonstrates why an existing, valid index can cost more than reading the heap sequentially.

## Mental Model

An index is a compact map from an indexed value to tuple locations in the heap. For a selective predicate, PostgreSQL can read a small index range and visit relatively few heap pages:

```text
B-tree range -> tuple locations -> selected heap pages
```

As more rows match, those locations spread across more heap pages. Eventually an index path reads much of the index and most or all of the heap, while a sequential scan reads each heap page once in physical order:

```text
large B-tree range + scattered heap visits
                        versus
one ordered pass through the heap
```

Selectivity is the fraction of rows that satisfy a predicate. Lower selectivity means fewer matches. Row width, physical clustering, cached pages, storage costs, concurrency, and required output columns all influence the crossover; there is no universal percentage at which an index stops winning.

## Scenario And Experiment

The runnable experiment is in [`benchmark/`](benchmark/). It creates deterministic event rows with a roughly 191-byte selected width and exactly one ordinary B-tree index:

```sql
CREATE INDEX events_match_bucket_idx ON events (match_bucket);
```

There is deliberately no primary-key or covering index. `payload` is returned but absent from the B-tree, so every qualifying tuple requires heap access. Multiplication by `7919`, which is coprime with 10,000, permutes all bucket values and keeps matching tuples spread through insertion order instead of clustering low buckets together.

Run the complete matrix with:

```bash
cd topics/database/index-selectivity/benchmark
./run.sh 100000
./run.sh 1000000
docker compose down
```

The Compose project is named `index-selectivity`. It runs PostgreSQL 17.6 Alpine, exposes database `index_selectivity` on `127.0.0.1:15437`, and stores PostgreSQL data on `tmpfs`.

The experiment matrix is:

| Rows | Predicate | Match ratio | Exact matching rows |
| ---: | --- | ---: | ---: |
| 100,000 | `match_bucket < 1` | 0.01% | 10 |
| 100,000 | `match_bucket < 10` | 0.1% | 100 |
| 100,000 | `match_bucket < 100` | 1% | 1,000 |
| 100,000 | `match_bucket < 1000` | 10% | 10,000 |
| 100,000 | `match_bucket < 5000` | 50% | 50,000 |
| 100,000 | `match_bucket < 9000` | 90% | 90,000 |
| 1,000,000 | The same six predicates | The same six ratios | Ten times the rows above |

Each case executes the full query once to warm it, discards that output, and then runs `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)`. No planner method is disabled in the main matrix. A high statistics target includes all 10,000 bucket values in analysis, making estimates exact for this controlled distribution.

Local observations are recorded in [`result/2026-09-02-postgresql-17-darwin-arm64.md`](result/2026-09-02-postgresql-17-darwin-arm64.md).

## Experiment And Result Interpretation

| Rows | Match ratio | Chosen plan | Actual rows | Shared buffers |
| ---: | ---: | --- | ---: | ---: |
| 100,000 | 0.01% | Bitmap heap scan | 10 | 12 |
| 100,000 | 0.1% | Bitmap heap scan | 100 | 102 |
| 100,000 | 1% | Bitmap heap scan | 1,000 | 868 |
| 100,000 | 10% | Bitmap heap scan | 10,000 | 2,871 |
| 100,000 | 50% | Sequential scan | 50,000 | 2,858 |
| 100,000 | 90% | Sequential scan | 90,000 | 2,858 |
| 1,000,000 | 0.01% | Bitmap heap scan | 100 | 103 |
| 1,000,000 | 0.1% | Bitmap heap scan | 1,000 | 1,003 |
| 1,000,000 | 1% | Bitmap heap scan | 10,000 | 8,641 |
| 1,000,000 | 10% | Bitmap heap scan | 100,000 | 28,658 |
| 1,000,000 | 50% | Bitmap heap scan | 500,000 | 28,991 |
| 1,000,000 | 90% | Sequential scan | 900,000 | 28,572 |

At low ratios, the bitmap index scan identifies relatively few tuple locations. The bitmap heap scan groups those locations by heap page, avoiding one random heap operation per tuple. At 0.01% in the million-row table, the plan needed 3 index buffers and 100 heap buffers rather than scanning 28,572 heap blocks.

As the match ratio rises, qualifying tuples occupy nearly every heap block. At 10% in both scales, the bitmap heap scan already visited every heap page, plus index pages. The index still helped PostgreSQL avoid testing every row, but it no longer avoided reading the heap.

At sufficiently high ratios PostgreSQL chose a sequential scan even though `events_match_bucket_idx` remained present and valid. The 100,000-row run crossed over at 50%; the million-row run crossed over at 90%. This is a planner cost choice, not index invalidation. The 50% million-row bitmap path illustrates the pressure: it read all 28,572 heap blocks plus 419 index blocks and took 121.708 ms locally, while the subsequent 90% sequential scan took 81.580 ms. Those timings are observations from one run, not a direct forced-plan comparison or a universal ratio.

Different crossover points at the two sizes are expected. PostgreSQL compares estimated costs, including heap pages, index pages, tuple processing, and access patterns. B-tree deduplication, relation size, cache pressure, and cost-model boundaries need not scale linearly. Read the plan and work performed instead of memorizing 50% or 90%.

## Source And Pseudocode Walkthrough

[`benchmark/run.sh`](benchmark/run.sh) accepts only the two documented row counts, starts the healthy container, and passes the size to [`benchmark/sql/run.sql`](benchmark/sql/run.sql). The SQL rebuilds the table on every run, so the million-row result does not append to the smaller table.

The deterministic distribution is generated as:

```sql
match_bucket = (id * 7919) % 10000
```

Conceptually:

```text
for id from 1 through row_count:
    bucket = permute(id) into 0..9999
    insert a wide event at the next heap position

create one B-tree on bucket
collect statistics

for threshold in [1, 10, 100, 1000, 5000, 9000]:
    execute the full row-returning query once to warm it
    explain and execute the same query with buffers enabled
```

Every query returns heap columns rather than reducing the experiment to `count(*)`:

```sql
SELECT id, account_id, created_at, status, payload
FROM events
WHERE match_bucket < 1000;
```

An index-only scan therefore cannot hide heap access. `TIMING OFF` removes per-node timer overhead while preserving execution, actual row counts, total execution time, and buffer accounting.

## Detailed Explanation

PostgreSQL does not apply a rule saying that a usable index must be used. It estimates candidate paths and chooses the lowest estimated cost. Here the useful candidates are a bitmap index scan followed by a bitmap heap scan, or a sequential scan with a filter.

A bitmap path separates index discovery from heap access. PostgreSQL first creates a bitmap of matching tuple locations, then visits heap pages in block order. That is usually better than a plain index scan for scattered multi-row matches, but it still has two components of work. It traverses the B-tree range, and it fetches every heap page represented in the bitmap. Once matches cover almost every heap page, the B-tree component becomes extra work compared with scanning the heap directly.

The selected width matters. A query that needs only `match_bucket`, or a count that can use an index-only scan after `VACUUM`, has a different cost shape because it may avoid the heap. This experiment returns event details to model an application endpoint that actually needs rows. Conversely, `SELECT *` with very large out-of-line values could add transfer and detoasting costs that obscure the foundational access-path effect.

The warmup reduces first-touch noise but cannot make a 223 MB heap fit in every PostgreSQL shared-buffer allocation. Buffer lines may consequently contain both hits and reads. Sum them when comparing total visited blocks, and do not interpret `tmpfs` reads as physical production-disk latency.

An index appearing in `pg_indexes` but not in a plan is not evidence that PostgreSQL invalidated, disabled, or forgot it. Index validity is schema state. Plan selection is a per-query cost decision based on the predicate, statistics, projected columns, relation size, and configured cost parameters. Inspect catalog validity separately if corruption or a failed concurrent build is genuinely suspected.

## Boundaries

- The bucket distribution is uniform and heap-scattered. Skew, correlation, hot values, and physical clustering can move the crossover substantially.
- The runs use default PostgreSQL cost settings in a local Docker `tmpfs`. SSD latency, cache size, `random_page_cost`, `effective_cache_size`, and concurrent load affect plan costs and observed time.
- Only one non-covering B-tree exists. Covering, partial, clustered, BRIN, or multiple combinable indexes answer different questions.
- The benchmark is read-only after load and `VACUUM`. Updates can change visibility, table bloat, cache residency, and statistics accuracy.
- Result transfer is discarded during warmup, and `EXPLAIN ANALYZE` does not send result tuples to an application. This isolates database access more than an end-to-end API benchmark would.
- The experiment identifies the chosen plan at six ratios, not the exact crossover point between adjacent ratios.

## Common Misconceptions

- "The index was invalidated when PostgreSQL chose a sequential scan." The index remains valid; the planner estimated that another valid access path was cheaper for that query.
- "An indexed predicate always uses the index." An index is a candidate path, not a command to the optimizer.
- "Indexes are useful only below a fixed selectivity percentage." The threshold depends on row width, clustering, cache, storage, query projection, relation size, and cost settings.
- "A bitmap heap scan avoids heap reads." It organizes heap access; it does not avoid the heap when requested columns are absent from the index.
- "More matching rows alone make a sequential scan faster." The relevant work includes how many heap pages those rows occupy. Clustered matches may touch far fewer pages than scattered matches at the same ratio.
- "Forcing `enable_seqscan = off` proves the index is better." Forced methods can diagnose alternatives, but they override normal costing and are not production tuning advice. This experiment does not force planner choices.
