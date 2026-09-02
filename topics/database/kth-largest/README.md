# Finding the x-th largest value

"Find the x-th largest" is ambiguous when values repeat. Before choosing SQL, define which result the product needs:

- X-th row: order every row and add a unique tie-breaker, such as `ORDER BY score DESC, id ASC`.
- X-th distinct value: remove duplicate scores before counting positions.
- Competition rank: equal scores share a rank and leave gaps, as with `rank()`.
- Dense rank: equal scores share a rank without gaps, as with `dense_rank()`.

This experiment measures the first two meanings and one read-optimized alternative.

## Experiment

The `scores` table has at most 10,000 score values, so larger runs contain many ties. Its `(score DESC, id ASC)` index makes row ordering deterministic and allows index-only scans.

The runnable PostgreSQL experiment is in [`benchmark/`](benchmark/). Run it from that directory:

```bash
cd topics/database/kth-largest/benchmark
./run.sh 100000
./run.sh 1000000
```

Remove the temporary database after the run with `docker compose down`.

It compares:

- The 100th ordered row.
- The row at 10% of the table.
- The row at 90% of the table.
- The 1,000th distinct score.
- The 90% row after all ranks have been materialized.

One local run is recorded in [`result/2026-09-01-postgresql-17-darwin-arm64.md`](result/2026-09-01-postgresql-17-darwin-arm64.md).

## Experiment And Result Interpretation

| Change | Observe | Interpretation |
| --- | --- | --- |
| Move from the 100th to the 900,000th ordered row | The index-only scan consumed 100 versus 900,000 entries. | A B-tree provides order but not subtree row counts, so `OFFSET x - 1` still performs work proportional to x. |
| Ask for the 1,000th distinct score | PostgreSQL consumed 99,901 index entries because many rows shared each score. | Distinct-value rank depends on both x and duplicate frequency; its semantics and cost differ from the x-th row. |
| Materialize `row_number()` and index `rank` | Rank 900,000 became a one-row, 4-buffer lookup, while the materialized table and index used 71 MB. | Precomputation moves work from reads to refreshes and storage. It fits repeated rank lookups only when freshness requirements tolerate that trade. |

The first question is semantic: decide whether ties mean `row_number()`, `rank()`, `dense_rank()`, or a distinct value. Only then does the execution-plan comparison answer the right problem.

## Detailed Explanation

A normal PostgreSQL B-tree stores ordered keys, but it does not expose subtree row counts for direct order-statistic lookup. `OFFSET x - 1 LIMIT 1` can avoid sorting when a suitable index exists, yet the index scan still produces approximately x entries before `Limit` returns one. Cost therefore grows with x, not only with table size.

A cursor helps when the caller already knows the preceding `(score, id)` value. It does not answer an arbitrary "give me rank 900,000" request because finding that cursor is the original order-statistic problem.

The experiment materializes `row_number()` into `ranked_scores` and indexes `rank`. Arbitrary rank lookup then becomes a point query, but building the table scans every score, consumes storage, and becomes stale whenever scores change. This can fit periodically refreshed leaderboards; it is usually a poor trade for rapidly changing exact ranks.

For the x-th distinct score, PostgreSQL must also consume duplicates before it has seen x unique values. Cost depends on both x and the number of rows per value.

## Boundaries

- Always include a stable tie-breaker if the requirement is an x-th row.
- `rank()`, `dense_rank()`, and `row_number()` have different product semantics; performance tuning cannot resolve that ambiguity.
- Approximate percentiles, exact arbitrary ranks, and adjacent-page navigation are different access patterns and may need different data structures.
- A cached or materialized leaderboard trades freshness and write work for predictable reads.
- Index-only scans depend on visibility-map state. Heap fetches can appear under active writes even with the same covering index.
