# Clustered index versus heap: 100,000-row run

Status: completed. All four full-table fingerprints and twelve query fingerprints matched the independent generator. The runner saved 156 plans (36 warmups and 120 measured executions). The four offline unit tests also passed.

The clearest result is within PostgreSQL: shuffled insertion spread a 1,000-row primary-key range across 879 heap pages, while ascending insertion allowed a compact index scan. InnoDB kept its clustered primary-range path for both insertion orders. Covering secondary queries reduced retrieval work in both engines under this read-only, warmed protocol.

## Environment and reproduction

- Date: 2026-10-01.
- Runner: `code/lab.py` and `benchmark/compose.yaml` from commit `ad04461`, executed on `9aedc23` with those files unchanged.
- Host: Apple M4 MacBook Air, 10 CPU cores, 16 GB RAM, macOS 27.0 arm64, internal NVMe SSD.
- Docker Desktop 4.88.1; client/server 29.7.2; Compose v5.4.0; Linux/arm64 VM with 10 CPUs and 7.75 GiB RAM.
- Python 3.14.3; standard library only.
- PostgreSQL 17.11 (Debian 17.11-1.pgdg13+2); MySQL 8.4.11, using InnoDB.
- Storage: isolated Docker named volumes backed by the VM, not `tmpfs`.
- Database buffers: PostgreSQL `shared_buffers=128MB`; InnoDB buffer pool 128 MiB. PostgreSQL parallel query and JIT disabled by the runner.
- Shared development machine: four other PostgreSQL containers were running. See [host context](2026-10-01-100k/host-notes.md) for load snapshots and startup troubleshooting.

The initial Docker Hub download failed before database startup. The measured attempt uses Docker Official Images from Amazon ECR Public, pinned to the downloaded digests. [Image identity and architecture](2026-10-01-100k/image-digests.json) are retained alongside the runner's engine-version records.

From the repository root:

```bash
cd topics/database/clustered-index-vs-heap
python3 -m unittest discover -s code -v
cd benchmark
PG_IMAGE=public.ecr.aws/docker/library/postgres@sha256:d74eeac9a635390a49bc21bd49fccd973de707e2a53a76ac49b552b8712ec46f \
MYSQL_IMAGE=public.ecr.aws/docker/library/mysql@sha256:6ea90827b1100f8f2ae306a539f86d2c264a26ed435a2a9f75551dd5c3aeb242 \
./run.sh 100000 result/run-2026-10-01-100k-ecr
```

Use a fresh output path when repeating the command. Each engine gets 100,000 identical rows in each of `rows_seq` and `rows_shuffled`, with 256-byte payloads and indexes built before insertion. The primary-key query returns IDs `[50000, 51000)` (1,000 rows); each `bucket = 42` query returns 100 rows. The runner verifies complete tables and query results before three warmup rounds and ten measured rounds, using a fixed randomized schedule. No `ORDER BY`, concurrent writers, or forced access paths are added.

## PostgreSQL observations

Times are PostgreSQL **Execution Time**, in milliseconds. Each row summarizes ten measured executions. The listed plan shapes and buffer counters were identical across those ten samples. Shared buffer hits below are the root's inclusive count; do not add the child count again.

| Query | Insertion order | Plan | Median ms | Min–max ms | Shared hits / reads | Heap detail |
| --- | --- | --- | ---: | --- | --- | --- |
| PK range + payload | Ascending | Index Scan on primary key | 0.2135 | 0.2050–0.3080 | 46 / 0 | Heap visits included in scan |
| PK range + payload | Shuffled | Bitmap Heap Scan | 1.3800 | 1.3420–3.5430 | 888 / 0 | 879 exact heap blocks |
| Secondary + payload | Ascending | Bitmap Heap Scan | 0.3620 | 0.3010–0.7400 | 104 / 0 | 100 exact heap blocks |
| Secondary + payload | Shuffled | Bitmap Heap Scan | 0.2965 | 0.2780–0.6270 | 101 / 0 | 98 exact heap blocks |
| Secondary covering | Ascending | Index Only Scan | 0.0510 | 0.0450–0.0670 | 5 / 0 | Heap Fetches = 0 |
| Secondary covering | Shuffled | Index Only Scan | 0.0490 | 0.0450–0.0660 | 4 / 0 | Heap Fetches = 0 |

### Why insertion order matters for the primary-key range

The recorded ID-to-heap correlation is `1` for `rows_seq` and `-0.0024882169` for `rows_shuffled`. Ascending insertion puts adjacent IDs in nearby heap tuples, even though the primary-key B-tree is separate from that heap. Its range scan recorded only 46 shared buffer hits across the index and heap work.

After shuffled insertion, the optimizer chose a Bitmap Index Scan followed by a Bitmap Heap Scan. The bitmap index child recorded 9 hits; the heap phase visited 879 exact heap blocks, producing the root total of 888. There were no lossy bitmap blocks. The bitmap groups tuple locations by heap page, but it cannot make scattered qualifying rows occupy fewer pages.

For this query, shuffling increased shared buffer hits by about 19.3× and median execution time by about 6.5× **within PostgreSQL**. These are not disk-read ratios: all measured PostgreSQL plans reported zero shared reads. The extra work was visible even with pages already in shared buffers.

### Why the secondary payload query does not follow the same pattern

`bucket = 42` selects one ID out of each 1,000 IDs. Those 100 matches are already spread across the ascending heap, so ordering the heap by ID gives little locality for this predicate. The bitmap heap scan visited 100 pages in the ascending table and 98 in the shuffled table. Their timing ranges overlap; the lower shuffled median does not establish a general shuffled-load advantage.

Removing `payload` lets `(bucket, id)` cover the projection. Both tables used Index Only Scan with **zero Heap Fetches in every measured sample**. The post-load `VACUUM (ANALYZE)` and absence of later writes made the visibility-map condition favorable. Shared hits dropped from 104 to 5 for the ascending table and from 101 to 4 for the shuffled table.

## MySQL / InnoDB observations

Times are the **root iterator's last-row time**, in milliseconds. This is a different measurement scope from PostgreSQL Execution Time, so these tables do not establish cross-engine speedup ratios. Each row summarizes ten measured executions with the same iterator shape.

| Query | Insertion order | Access path | Median ms | Min–max ms |
| --- | --- | --- | ---: | --- |
| PK range + payload | Ascending | PRIMARY index range scan + root filter | 0.1650 | 0.1520–0.2000 |
| PK range + payload | Shuffled | PRIMARY index range scan + root filter | 0.1955 | 0.1760–0.2680 |
| Secondary + payload | Ascending | Index lookup on `(bucket, id)` | 0.1575 | 0.1270–0.2730 |
| Secondary + payload | Shuffled | Index lookup on `(bucket, id)` | 0.1815 | 0.1370–0.3980 |
| Secondary covering | Ascending | Covering index lookup on `(bucket, id)` | 0.0141 | 0.0119–0.0187 |
| Secondary covering | Shuffled | Covering index lookup on `(bucket, id)` | 0.0145 | 0.0130–0.0289 |

Both primary-range plans scanned `PRIMARY` over `50000 <= id < 51000`, returning 1,000 rows through a filter. InnoDB's clustered leaf records contain the payload, so this path does not need PostgreSQL's separate heap traversal. The shuffled median was about 18% higher, with overlapping ranges. Logical key order survives shuffled insertion, but identical occupancy and timing do not follow from that property.

For the secondary payload query, the plan reports an index lookup, which internally retrieves clustered records using their primary keys. Those internal lookups are not printed as 100 separate operators. The covering projection instead reports `Covering index lookup` and has a much lower median in both tables. The plans provide no comparable buffer/page counter and do not independently count MVCC-related clustered visits, so no MySQL physical-I/O count is inferred.

## Storage observations

Sizes are MiB (bytes / 1,048,576), rounded to two decimals. These are engine-specific accounting fields, not a cross-engine storage-efficiency ranking.

| Engine | Insertion order | Main storage | Index storage | Total relation storage |
| --- | --- | ---: | ---: | ---: |
| PostgreSQL | Ascending | Heap: 28.94 | All indexes: 6.97 | 35.94 |
| PostgreSQL | Shuffled | Heap: 28.94 | All indexes: 6.85 | 35.82 |
| InnoDB | Ascending | DATA_LENGTH: 30.56 | INDEX_LENGTH: 2.52 | — |
| InnoDB | Shuffled | DATA_LENGTH: 49.58 | INDEX_LENGTH: 2.52 | — |

PostgreSQL's heaps have equal size despite very different ID locality. Heap size alone does not predict the number of pages needed for a particular predicate.

InnoDB's estimated clustered storage was about 62% larger after shuffled insertion. This is consistent with insertion-order-dependent page splits and occupancy. The experiment did not measure page fill or split counts directly, so the size difference is evidence of a layout cost, not a quantified split mechanism or insert-throughput result. InnoDB `DATA_LENGTH` includes clustered storage; its `INDEX_LENGTH` covers secondary indexes, unlike PostgreSQL's all-index column.

## Evidence and completion

The compact evidence is retained in [`2026-10-01-100k/`](2026-10-01-100k/):

- [`manifest.json`](2026-10-01-100k/manifest.json) and [`verified-checksums.json`](2026-10-01-100k/verified-checksums.json): independent expected fingerprints and all sixteen successful checks.
- [`queries.sql`](2026-10-01-100k/queries.sql): the exact six SQL statements used on each engine.
- [`measurements.csv`](2026-10-01-100k/measurements.csv), [`summary.json`](2026-10-01-100k/summary.json), and [`execution-order.json`](2026-10-01-100k/execution-order.json): all 120 samples, statistics, and the 156-plan schedule including warmups.
- [`plans/`](2026-10-01-100k/plans/): every raw plan, not just the fastest sample.
- [`versions.json`](2026-10-01-100k/versions.json), [`environment.json`](2026-10-01-100k/environment.json), settings, correlation, and size TSVs: the measured runtime and configuration.
- [`STATUS.txt`](2026-10-01-100k/STATUS.txt): successful database execution marker, with verified root loops and PostgreSQL plan row counts.

The large deterministic `pg-load.sql` and `mysql-load.sql` inputs remain in the ignored local run directory and can be regenerated from the command above. Their records are described by the retained manifest. The run used project `index-layout-21abb89a734e`; after evidence capture, its two containers and network were removed with the scoped `docker compose ... down` command. Its named volumes remain available.

## What this supports, and where it stops

- **Primary-key locality matters when the query retrieves row payloads.** An ascending PostgreSQL heap already benefits from locality; a shuffled one makes the separate heap cost visible. InnoDB retains logical primary-key clustering, while insertion order can still affect storage footprint.
- **Locality is relative to the access predicate.** ID ordering helped the contiguous ID range, but did little for the bucket query whose matches were spread throughout the ID space.
- **Covering projections can remove substantial row-retrieval work.** This run observed zero PostgreSQL heap fetches after vacuum and covering MySQL index lookups in a fresh, read-only dataset. Writes and visibility checks can change that behavior.
- **This is one 100k-row, single-client, warmed run on a shared laptop.** The PostgreSQL shuffled-range maximum was 3.543 ms versus a 1.380 ms median; background activity and instrumentation can affect sub-millisecond measurements. Ten samples describe this run, not independent repetitions across hosts or fresh loads.
- A larger working set, cold-cache protocol, concurrent clients, updates, or wider keys needs a separate experiment. No production capacity, physical disk I/O, write throughput, or universal database ranking follows from these results.
