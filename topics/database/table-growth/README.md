# Database table growth

This topic uses small experiments to understand which problems gradually appear as relational database tables grow.

## Problem Background

A business table may have only a few thousand rows early on, making queries, updates, and schema changes feel easy. As the table grows to millions or tens of millions of rows, problems that were previously invisible begin to appear.

For example:

- Queries without indexes become slow.
- Deep pagination gets slower.
- Aggregation queries consume more resources.
- DDL on large tables becomes risky.
- Backups, restores, and archival jobs take longer.
- Hot and cold data share the same table and affect common queries.

## Mental Model

A small table is like a thin notebook: scanning through it is still cheap.

A large table is more like an archive building. Without an index, finding one file means searching from beginning to end; with too many indexes, each new file requires maintaining many index cards.

## Experiment Directions

Future work can add:

- Queries with and without indexes.
- `EXPLAIN` query-plan observations.
- `LIMIT/OFFSET` deep pagination compared with cursor-based pagination.
- The effect of index count on insert performance.
- Wide rows, large columns, and covering indexes.
- Hot/cold data splitting or archival strategies.

## Focus

This topic is not only about "optimizing SQL"; it is about understanding how engineering maintenance costs change as data grows.

## Next Additions

- Docker Compose database setup.
- Data-generation scripts.
- Repeatable SQL experiments.
- Query-plan and latency result records.
