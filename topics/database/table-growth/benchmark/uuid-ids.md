# UUID primary keys

Choosing UUID instead of `bigint` changes more than the textual shape of an ID. This experiment separates two pressures that are often mixed together:

- Key width: PostgreSQL stores native `uuid` in 16 bytes and `bigint` in 8 bytes.
- Insertion locality: increasing keys usually reach the right edge of a B-tree, while random UUIDs insert across many leaf pages.

## Cases

| Table | Key | Input order | Question |
| --- | --- | --- | --- |
| `bigint_ids` | Increasing `bigint` | Increasing | Small, ordered baseline |
| `ordered_uuid_ids` | Synthetic increasing `uuid` | Increasing | What changes when the key is wider but remains ordered? |
| `random_uuid_ids` | Deterministic MD5-derived `uuid` | Random key order | What additional cost appears when inserts lose locality? |

The ordered UUID is deliberately synthetic. It is a control variable, not an ID-generation recommendation or an implementation of UUIDv7. The random UUIDs are generated before measurement so hashing does not count as insertion work.

Run:

```bash
./run.sh uuid-ids 100000
./run.sh uuid-ids 1000000
```

Inspect:

- `Buffers` and `WAL` for each `INSERT`; treat one run's execution time as secondary evidence.
- Primary-key index and total relation size.
- B-tree depth as indirectly reflected by buffers visited during point lookup.

## Expected Shape

The ordered UUID index should generally be larger than the `bigint` index because every key and internal separator is wider. The random UUID index may be larger again because incremental random insertion tends to leave pages less densely packed and causes more page splits.

Point lookup can remain similarly fast while all indexes fit in memory and have similar height. This is why a small point-query benchmark can miss UUID's storage, cache, WAL, and write-locality costs. Differences become more important when the index stops fitting comfortably in memory or writes are sustained and concurrent.

Time-ordered identifiers such as UUIDv7 can improve insertion locality while retaining decentralized generation, but they remain wider than `bigint` and expose approximate creation time. Their behavior also depends on generation quality and ordering among IDs created in the same time interval.

## Boundaries

- Use PostgreSQL's native `uuid`, not a 36-character text column, when the domain is UUID.
- Random UUIDs can be useful when IDs must be generated independently across systems. That operational property may outweigh index cost.
- Sequential IDs are not an authorization mechanism. Guessability and access control are separate concerns.
- Bulk index construction can pack random values differently from continuous random inserts. This experiment intentionally measures incremental primary-key maintenance.
- One bulk insert does not reproduce long-running bloat, cache eviction, checkpoints, replicas, or concurrent page contention.
- Fixed execution order can affect cache and checkpoint timing. Compare WAL and relation size before treating a small elapsed-time difference as meaningful.
