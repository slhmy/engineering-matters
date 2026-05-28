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
- [Cache](topics/cache/): Track common cache behaviors and practices, such as cache penetration, cache breakdown, cache avalanche, and hot keys.

## Writing Principles

- Explain the scenario before the solution.
- Run the experiment before drawing conclusions.
- Avoid "always do this"; explain when a choice is more suitable.
- Use small pieces of code to reveal real costs in larger systems.
- Keep conclusions bounded so they do not become dogma.

## Status

This repository is still in its early stage. The first version establishes the topic skeletons. Runnable code, benchmarks, data-generation scripts, and experiment results will be added gradually.
