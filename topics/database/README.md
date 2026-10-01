# Database topics

These labs examine how relational database choices behave as data volume or access patterns change. Most use PostgreSQL; selected labs also compare MySQL/InnoDB. Each topic keeps one problem boundary and can be run independently.

## Topics

| Topic | Engineering pressure | Main comparison |
| --- | --- | --- |
| [Table growth](table-growth/) | More rows make previously cheap access paths visible. | Sequential scan vs indexed lookup; deep `OFFSET` vs cursor pagination |
| [Clustered index versus heap](clustered-index-vs-heap/) | An index seek can still require row retrieval through a different storage structure. | PostgreSQL heap vs InnoDB clustered rows; sequential/shuffled insertion, range/secondary/covering reads (100k-row results recorded) |
| [Index selectivity](index-selectivity/) | An indexed predicate can still match too much of the table to save work. | Bitmap heap scan vs sequential scan across six match ratios |
| [Point lookup versus range scan](point-vs-range-scan/) | A cheap B-tree seek does not eliminate the cost of reading a large range. | One row, fixed range, and 1%/10%/50% ranges |
| [Sorting and LIMIT](sorting-and-limit/) | A small output limit does not always permit an early stop. | Top-N heap, full sort, and ordered index scan |
| [Transaction isolation](transaction-isolation/) | Concurrent decisions can each be locally valid but globally inconsistent. | Statement snapshots, transaction snapshots, write skew, and SSI aborts |
| [Row locking](row-locking/) | Conflicting writes must wait, fail, skip, or recover from a dependency cycle. | Same/different rows, `NOWAIT`, `SKIP LOCKED`, and deadlock detection |
| [UUID primary keys](uuid-primary-keys/) | Identifier width and insertion order affect B-tree maintenance. | Sequential `bigint`, ordered UUID, and random UUID |
| [Finding the x-th largest](kth-largest/) | An ordered index does not directly provide arbitrary row ranks. | Shallow/deep index offsets, distinct values, and materialized ranks |
| [Composite index column order](composite-index-order/) | The same columns can produce different scan ranges and optimizer fallbacks across engines. | PostgreSQL/MySQL leading prefixes, skip scan, omitted predicates, and `ORDER BY` compatibility |

The topics are related but not interchangeable. Table size is an input to these experiments; the decision under study is different in each one.

## Running Labs

Runnable topics contain their own `benchmark/compose.yaml`, `benchmark/run.sh`, and SQL or a deterministic data generator. Run commands from that topic's `benchmark/` directory and read its README for prerequisites and result status. Compose projects use separate names and databases; published host ports, when present, are topic-specific. The clustered-index-versus-heap lab publishes no host ports and includes a measured 100k-row report with raw plans.

Treat recorded timings as local observations. Query plans, actual rows, buffers, WAL, and relation sizes usually explain more than one elapsed-time number.

