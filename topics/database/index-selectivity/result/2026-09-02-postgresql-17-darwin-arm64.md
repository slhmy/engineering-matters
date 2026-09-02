# Index selectivity results

These are local observations from the controlled matrix. They document plan shape and visited work, not universal latency ratios or crossover percentages.

## Environment

- Date: 2026-09-02
- Host: macOS 26.5.1, Darwin arm64
- Docker client and server: 29.6.2
- PostgreSQL: 17.6 (`postgres:17.6-alpine`)
- Database: `index_selectivity`
- Storage: Docker `tmpfs`
- Commands: `./run.sh 100000` and `./run.sh 1000000`
- Measurement: one full-query warmup followed by `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)`
- Planner methods and PostgreSQL cost settings: defaults; no scan type was forced

## Observations

| Rows | Match ratio | Estimated / actual rows | Plan | Heap blocks | Index blocks | Total shared buffers | Execution time |
| ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: |
| 100,000 | 0.01% | 10 / 10 | Bitmap heap scan | 10 | 2 | 12 | 0.017 ms |
| 100,000 | 0.1% | 100 / 100 | Bitmap heap scan | 100 | 2 | 102 | 0.042 ms |
| 100,000 | 1% | 1,000 / 1,000 | Bitmap heap scan | 865 | 3 | 868 | 0.534 ms |
| 100,000 | 10% | 10,000 / 10,000 | Bitmap heap scan | 2,858 | 13 | 2,871 | 2.597 ms |
| 100,000 | 50% | 50,000 / 50,000 | Sequential scan | 2,858 | 0 | 2,858 | 5.462 ms |
| 100,000 | 90% | 90,000 / 90,000 | Sequential scan | 2,858 | 0 | 2,858 | 6.325 ms |
| 1,000,000 | 0.01% | 100 / 100 | Bitmap heap scan | 100 | 3 | 103 | 0.046 ms |
| 1,000,000 | 0.1% | 1,000 / 1,000 | Bitmap heap scan | 1,000 | 3 | 1,003 | 0.544 ms |
| 1,000,000 | 1% | 10,000 / 10,000 | Bitmap heap scan | 8,630 | 11 | 8,641 | 12.042 ms |
| 1,000,000 | 10% | 100,000 / 100,000 | Bitmap heap scan | 28,572 | 86 | 28,658 | 55.873 ms |
| 1,000,000 | 50% | 500,000 / 500,000 | Bitmap heap scan | 28,572 | 419 | 28,991 | 121.708 ms |
| 1,000,000 | 90% | 900,000 / 900,000 | Sequential scan | 28,572 | 0 | 28,572 | 81.580 ms |

The 100,000-row heap was 22 MB and its B-tree was 936 kB. The million-row heap was 223 MB and its B-tree was 6,712 kB.

At 0.01%, the B-tree and bitmap restricted heap access to one page per matching row in this scattered layout. By 10%, matching tuples occupied every heap block at both sizes. The bitmap plan then read the entire heap plus its qualifying B-tree range.

PostgreSQL naturally selected a sequential scan for the 50% and 90% predicates at 100,000 rows. At one million rows it retained the bitmap path for 50%, with an estimated cost of 40,377.43 versus the sequential scan's fixed full-table cost of 41,072.00 shown by the 90% plan. It selected the sequential scan at 90%.

The million-row 50% bitmap plan took longer locally than the 90% sequential plan even though the latter returned 400,000 more rows. This is not a controlled timing comparison between scan methods for one predicate, so it does not prove an exact speed ratio. It does expose the extra index work and the sensitivity of elapsed time to cache state when all heap blocks are needed.

## Caveats

- Warm queries ran immediately before each explanation, but the 223 MB heap exceeded the container's effective shared cache during broad scans. The million-row plans contain changing mixes of shared hits, reads, and writes.
- Docker `tmpfs` removes persistent-disk behavior. Buffer counts and plan shapes are more transferable than these sub-second timings.
- The high statistics target makes estimates exact for these 10,000 uniform buckets. Production statistics are usually sampled and real data may be skewed or correlated.
- The payload creates a realistic non-covering projection, but application network transfer and client processing are not measured.
- The different 50% choices at the two table sizes are a useful warning, not a PostgreSQL guarantee: selectivity alone does not determine the plan.
