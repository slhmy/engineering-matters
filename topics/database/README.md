# Database topics

These labs examine how relational database choices behave as data volume or access patterns change. They share PostgreSQL as an experiment engine, but each topic keeps one problem boundary and can be run independently.

## Topics

| Topic | Engineering pressure | Main comparison |
| --- | --- | --- |
| [Table growth](table-growth/) | More rows make previously cheap access paths visible. | Sequential scan vs indexed lookup; deep `OFFSET` vs cursor pagination |
| [UUID primary keys](uuid-primary-keys/) | Identifier width and insertion order affect B-tree maintenance. | Sequential `bigint`, ordered UUID, and random UUID |
| [Finding the x-th largest](kth-largest/) | An ordered index does not directly provide arbitrary row ranks. | Shallow/deep index offsets, distinct values, and materialized ranks |
| [Composite index column order](composite-index-order/) | The same columns can produce very different scan ranges when their order changes. | Leading equality prefixes, omitted predicates, and `ORDER BY` compatibility |

The topics are related but not interchangeable. Table size is an input to these experiments; the decision under study is different in each one.

## Running Labs

Each topic contains its own `benchmark/compose.yaml`, `benchmark/run.sh`, SQL, and recorded local results. Run commands from that topic's `benchmark/` directory. The Compose projects use separate names, databases, and host ports, so one lab does not depend on another lab's container.

Treat recorded timings as local observations. Query plans, actual rows, buffers, WAL, and relation sizes usually explain more than one elapsed-time number.
