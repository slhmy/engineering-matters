# Cache

The cache category records common cache behaviors, risks, and practices in backend systems. Each behavior is kept as a separate lab so its workload and tradeoffs remain visible.

## Available Labs

- [Cache breakdown](cache-breakdown/): Compare naive cache-aside, request coalescing, and stale-while-revalidate when concurrent requests observe one expired hot key.
- [Cache avalanche](cache-avalanche/): Compare aligned expiry, random TTL jitter, and deliberate staggering under unlimited and capacity-limited origins.

## Planned Topics

- Cache penetration: requested data does not exist, so requests keep reaching the database.
- Hot keys: a small number of keys receive extremely high traffic.
- Cache consistency: timing problems between writing the database and deleting or updating the cache.
- Local cache vs distributed cache: tradeoffs among latency, capacity, and consistency.

## Experiment And Result Interpretation

Cache labs should keep origin latency and request rate fixed, then change one cache condition at a time. The expired-hot-key row is covered by the runnable cache-breakdown lab; the other rows remain expected signals for planned topics.

| Change | Observe | Interpretation |
| --- | --- | --- |
| Request nonexistent keys with and without negative caching | Origin requests per second and repeated misses for the same key | If origin load follows miss traffic, the cache is not absorbing penetration. Negative entries trade freshness and cache space for origin protection. |
| Expire one hot key under concurrent traffic | Peak origin concurrency and request latency around expiration | A hot-key expiry can turn one miss into many simultaneous origin requests. Request coalescing reduces duplicate work but makes one loader a coordination point. |
| Expire many keys at the same time, then add TTL jitter | Origin request-rate distribution over time | Jitter spreads refresh work rather than removing it. A lower peak with similar total work demonstrates load shaping, not free capacity. |

Result interpretation should compare origin work, tail latency, and stale-data behavior together. A higher cache hit ratio alone does not explain whether the system is safer during expiry or failure.

## Source And Pseudocode Walkthrough

Most cache-aside failure modes begin with the same small read path:

```text
entry = cache.get(key)
if entry is fresh:
    return entry.value

value = origin.load(key)
cache.set(key, value, ttl)
return value
```

The important behavior is hidden between "not fresh" and `origin.load`: how many requests can enter that interval, whether they coordinate by key, whether stale data can be served, and whether nonexistent values are cached. The [cache breakdown source walkthrough](cache-breakdown/#source-and-pseudocode-walkthrough) makes those choices explicit for one hot expired key.

## Writing Style

Each cache topic should include:

- An easy-to-understand business story.
- A minimal reproducible model.
- Observed behavior.
- Common solutions.
- The costs and boundaries of those solutions.
