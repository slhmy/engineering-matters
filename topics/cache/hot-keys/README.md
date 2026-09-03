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

| Change | Observe | Interpretation |
| --- | --- | --- |
| Increase nodes under uniform traffic | Busiest-node requests fall approximately with average load. | Many independent keys give hashing enough units to distribute. |
| Increase nodes while one key owns 50% of traffic | The busiest node remains near 50% of all requests. | A logical key is still one indivisible routing unit, regardless of cluster width. |
| Increase nodes under Zipf traffic | Absolute busiest-node load falls slowly and `Max/mean` grows. | More nodes lower the mean faster than they lower load from the hottest key. |
| Replicate known hot keys | Maximum physical key-copy load and busiest-node load fall. | Replication turns one logical routing unit into several read-serving units. |

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
