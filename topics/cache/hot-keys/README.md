# Hot keys

Suppose a cache cluster stores 10,000 product records. Most products receive modest traffic, but a flash sale sends half of all reads to one product. The cache hit ratio can remain nearly 100% while one cache node saturates because consistent hashing normally places every request for that product on the same node.

This is a hot-key problem: the request distribution across logical keys creates a physical bottleneck even though the cache contains the requested data.

## Why More Shards May Not Help

Hash partitioning spreads different keys across nodes:

```text
hash(key) -> one cache node
```

Adding nodes lowers average load when keys are reasonably uniform. It does not split requests for one key, because identical keys keep producing the same routing decision. Average requests per node can therefore look safe while the busiest node is overloaded.

This differs from:

- [Cache breakdown](../cache-breakdown/), where one key expires and concurrent misses duplicate origin work.
- [Cache avalanche](../cache-avalanche/), where many keys create correlated refresh work.
- [Cache penetration](../cache-penetration/), where nonexistent keys bypass ordinary value caching.

The hot-key experiment keeps every request as a cache hit and changes only key popularity, node count, and selected-key replication.

## Workloads

| Workload | Default distribution | Question |
| --- | --- | --- |
| `uniform` | One million requests evenly cover 10,000 keys. | Does ordinary hash sharding balance a broad key set? |
| `zipf-1.2` | A deterministic Zipf distribution concentrates traffic on low-ranked keys. | How does a realistic long tail affect node balance? |
| `hot-50` | Key zero receives 50% of all requests; other keys share the rest. | Can adding nodes relieve one dominant key? |

## Strategies

The baseline assigns one physical copy per logical key and varies the cluster from 1 to 64 nodes.

The mitigation cases assume the ten hottest keys have already been identified. They create 4 or 16 read replicas for those keys across a fixed 16-node cluster and choose a replica independently for each request.

```text
single copy:   hot key -> node 7
four replicas: hot key -> node 7, 8, 9, or 10
```

Replication here is a load-distribution mechanism, not ordinary failover replication where clients continue reading one primary.

## Experiment Model

The runnable Go model is in [`benchmark/`](benchmark/). It generates deterministic request traces, routes them through a stable integer hash, and counts requests assigned to every node and physical key replica.

Default variables:

| Variable | Value |
| --- | ---: |
| Requests per workload | 1,000,000 |
| Logical keys | 10,000 |
| Baseline cache nodes | 1, 4, 16, 64 |
| Nodes in replication cases | 16 |
| Identified hot keys | 10 |
| Replicas per identified key | 4, 16 |
| Assumed node capacity | 100,000 requests/s |

Run it with:

```bash
cd topics/cache/hot-keys/benchmark
go test ./...
go run .
```

Change the matrix with:

```bash
go run . \
  -requests=2000000 \
  -keys=100000 \
  -nodes=1,8,32,128 \
  -replication-nodes=32 \
  -replicated-keys=20 \
  -replicas=4,16,32 \
  -node-capacity=200000
```

A local default run is recorded in [`result/2026-09-03-darwin-arm64.md`](result/2026-09-03-darwin-arm64.md).

## What To Observe

- `Hottest logical key`: request count before any physical replication.
- `Busiest node`: highest request count assigned to one cache node.
- `Busiest share`: fraction of all requests handled by that node.
- `Max/mean`: busiest-node load divided by average node load.
- `Max key replica`: highest request count received by one physical copy of any key.
- `Minimum drain time`: busiest-node requests divided by assumed node capacity; this is modeled time, not a measured latency.

The busiest node determines whether the trace fits cluster capacity. Total capacity calculated as `nodes * capacity` is insufficient when traffic is imbalanced.

## Experiment And Result Interpretation

The table below reads the default run in [`result/2026-09-03-darwin-arm64.md`](result/2026-09-03-darwin-arm64.md). Each row changes one routing condition and follows the resulting node load.

| Change | Observe in the local run | Interpretation |
| --- | --- | --- |
| Grow a uniform trace from 1 to 16 nodes | Busiest node fell from 1,000,000 to 66,800 requests, close to the 62,500 mean; at 64 nodes it reached 18,700 with `Max/mean` only `1.20x`. | Many independent keys give hashing enough units to distribute; growth spreads them. |
| Grow `hot-50` from 16 to 64 nodes | Busiest node fell only from 532,502 to 509,300 requests, while `Max/mean` rose from `8.52x` to `32.60x`. | The extra nodes divide the cold 500,000 requests, but the single-copy hot key still lands on one node. |
| Grow `zipf-1.2` to 64 nodes | Busiest node held 213,438 requests against a mean of 15,625, a `13.66x` ratio, even though the hottest key received only 207,632. | A skewed but not single-key trace still concentrates work, so average load understates the busiest node. |
| Replicate the 10 hottest keys on 16 nodes | `hot-50` busiest node fell from 532,502 to 64,661 with 16 replicas, and the `Max key replica` column fell from 500,000 to 31,823. | Replication turns one logical routing unit into several read-serving units; serialization moves to each physical copy. |

Read the `Hottest logical key` and `Busiest node` columns together. When they are nearly equal, as in every unreplicated `hot-50` row, the busiest node *is* the hot key and no amount of sharding can lower it. The `Max key replica` column shows how replication lowers that indivisible floor rather than just reshuffling the rest.

## Source And Pseudocode Walkthrough

The complete model is [`benchmark/main.go`](benchmark/main.go). It has three stages: build a deterministic request trace, route every request to a physical replica, and aggregate per-node and per-replica counts.

`makeWorkloads` fixes key popularity before routing begins:

```go
uniformKey := i % keyCount
hotKey := 0
if i%2 == 1 {
	hotKey = 1 + (i/2)%(keyCount-1)
}
```

Every even request sets `hotKey = 0`, so exactly half of the one million requests target one logical key. This is why `hot-50` reports `Hottest logical key = 500000`. The Zipf generator uses the fixed `-seed` value, which is why rerunning reproduces `207632` for `zipf-1.2`.

`distribute` contains the routing decision that explains every result:

```go
primary := int(mix64(uint64(key)) % uint64(nodes))
replica := 0
if key < replicatedKeys && replicasPerHotKey > 1 {
	replica = int(mix64(uint64(requestID)+0x9e3779b97f4a7c15) % uint64(replicasPerHotKey))
}
node := (primary + replica) % nodes
```

The first line is the indivisible-key constraint: every request for the same `key` computes the same `primary`, so changing `nodes` changes the modulus but not the fact that all requests for that key meet at one node. The conditional is the mitigation: only the first `replicatedKeys` logical keys are spread, and each of their requests selects a replica from the request ID. `max(w.keyCounts)` produces the `Hottest logical key` column, `max(nodeLoads)` produces `Busiest node`, and `max(replicaLoads)` produces `Max key replica`. `minDrainTime` then divides the busiest-node count by the assumed `node-capacity`, which is why all drain times fall when `Busiest node` falls.

## Why It Happens

With uniform traffic, each additional node receives a smaller sample of many keys. Hash imbalance and finite key count still prevent perfect equality, but total load is broadly divisible.

With one key receiving 500,000 of one million requests, any single-copy design must send at least those 500,000 requests to one node. The lower bound on busiest-node load is therefore approximately:

```text
busiest node >= hottest unreplicated key
```

Adding nodes only redistributes the remaining 500,000 requests. It cannot cross that lower bound.

Creating 16 independently selected read copies lowers the ideal per-copy hot load from 500,000 to about 31,250 requests. Other keys and finite routing variation still contribute node load, but the original indivisible unit has been split.

## Boundaries

- The trace contains cache hits only. It does not include origin fallback, expiry, network latency, or eviction.
- Node capacity and drain time are arithmetic assumptions. Real capacity depends on payload size, protocol, CPU, memory bandwidth, and connection behavior.
- The experiment already knows the ten hottest keys. Production systems need timely heavy-hitter detection and must handle keys becoming hot or cooling down.
- Replicas contain identical read values. Mutable values require invalidation or update fan-out, and clients may observe replicas at different versions.
- Replicating counters or read-modify-write state changes semantics and cannot be treated as simple read replication.
- Replica placement is deterministic and adjacent from the primary node in this model. Production placement should consider failure domains and existing node load.
- Local caches can absorb hot reads before the distributed cache, but multiply copies and introduce process-level staleness and invalidation problems.
- A CDN or edge cache may be a better layer for public immutable content; private or rapidly changing data has different constraints.

## Common Misconceptions

- A high cache hit ratio does not imply healthy cache-node load.
- Adding shards does not divide one hot key unless the routing representation of that key also changes.
- Total cluster QPS capacity does not guarantee safety when one node receives a disproportionate share.
- Read replication is not free horizontal scaling; it adds placement, routing, memory, invalidation, and observability work.
- Randomly suffixing a key is safe only when every suffix represents an acceptable copy and the read/write consistency model is explicit.

## Small Conclusion

Hash sharding scales traffic that is divisible across many keys. It cannot remove the load floor imposed by the hottest single-copy key. Replicating known read-hot values can divide that key's traffic, but it trades node pressure for extra copies, routing logic, detection, and consistency work.
