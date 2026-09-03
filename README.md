# engineering-matters

Small experiments for understanding why engineering choices matter.

`engineering-matters` is a learning repository for backend engineering practice. It does not try to hand out universal "standard answers"; it uses approachable scenarios, reproducible experiments, and explicit boundaries to explain why engineering choices matter.

## Why This Repository Exists

Many engineering problems are hard to see at small scale:

- In Go, when multiple goroutines read and write a map concurrently, should you choose `sync.Map`, `map + mutex`, or a sharded map?
- After a relational database table grows, why do indexes, pagination, DDL, and archival work become harder?
- Why do caches suffer from cache penetration, cache breakdown, cache avalanche, and hot keys?
- What problems do "best practices" such as retries, rate limiting, idempotency, and connection pools actually solve?

This repository breaks those questions into small experiments so readers can understand the scenario first, observe the behavior, and then form judgment.

## Organization

```text
topics/
  go/
    sync-map/
  database/
    table-growth/
    index-selectivity/
    point-vs-range-scan/
    sorting-and-limit/
    transaction-isolation/
    row-locking/
    uuid-primary-keys/
    kth-largest/
    composite-index-order/
  cache/
```

Each topic should generally cover:

- What the problem is.
- When it appears.
- What the intuitive first solution is.
- How the experiment is designed.
- How to run the experiment.
- What results were observed.
- Why the behavior happens.
- Where the approach fits.
- Where it does not fit.
- Common misconceptions.

## Initial Topics

- [Go sync map](topics/go/sync-map/): Compare several concurrent map strategies under different read/write ratios, key distributions, and hot-key access patterns.
- [Database table growth](topics/database/table-growth/): Understand why queries, indexes, pagination, and maintenance work become more complex as relational database tables grow.
- [Index selectivity](topics/database/index-selectivity/): Observe why an existing index can lose to a sequential scan as more rows match.
- [Point lookup versus range scan](topics/database/point-vs-range-scan/): Separate the cost of finding a range boundary from reading and returning the range.
- [Sorting and LIMIT](topics/database/sorting-and-limit/): Compare top-N sorting, full sorting, and early stop through an order-compatible index.
- [Transaction isolation](topics/database/transaction-isolation/): Reproduce changing snapshots, write skew, and serialization failures with controlled concurrent sessions.
- [Row locking](topics/database/row-locking/): Observe row-level waiting, `NOWAIT`, `SKIP LOCKED`, and deadlock recovery.
- [UUID primary keys](topics/database/uuid-primary-keys/): Separate the storage cost of wider keys from the B-tree locality cost of random insertion.
- [Finding the x-th largest](topics/database/kth-largest/): Compare indexed offsets, distinct-value ranking, and materialized ranks.
- [Composite index column order](topics/database/composite-index-order/): Understand how equality prefixes, omitted predicates, and ordering requirements determine useful index column order.
- [Cache](topics/cache/): Track common cache behaviors and practices, such as cache penetration, cache breakdown, cache avalanche, and hot keys.

## Writing Principles

- Explain the scenario before the solution.
- Run the experiment before drawing conclusions.
- Avoid "always do this"; explain when a choice is more suitable.
- Use small pieces of code to reveal real costs in larger systems.
- Keep conclusions bounded so they do not become dogma.

## Status

This repository is still in its early stage. The first version establishes the topic skeletons. Runnable code, benchmarks, data-generation scripts, and experiment results will be added gradually.
