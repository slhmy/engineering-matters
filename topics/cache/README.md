# Cache

The cache category records common cache behaviors, risks, and practices in backend systems.

This topic is currently a stub: it does not yet contain runnable code or recorded benchmark results.

## Planned Topics

- Cache penetration: requested data does not exist, so requests keep reaching the database.
- Cache breakdown: a hot key expires and many requests fall back to the origin at the same time.
- Cache avalanche: many keys expire together and put sudden pressure on downstream systems.
- Hot keys: a small number of keys receive extremely high traffic.
- Cache consistency: timing problems between writing the database and deleting or updating the cache.
- Local cache vs distributed cache: tradeoffs among latency, capacity, and consistency.

## Experiment And Result Interpretation

The first runnable lab should keep origin latency and request rate fixed, then change one cache condition at a time. Until that lab exists, the following are expected signals rather than observed repository results.

| Change | Observe | Interpretation |
| --- | --- | --- |
| Request nonexistent keys with and without negative caching | Origin requests per second and repeated misses for the same key | If origin load follows miss traffic, the cache is not absorbing penetration. Negative entries trade freshness and cache space for origin protection. |
| Expire one hot key under concurrent traffic | Peak origin concurrency and request latency around expiration | A hot-key expiry can turn one miss into many simultaneous origin requests. Request coalescing reduces duplicate work but makes one loader a coordination point. |
| Expire many keys at the same time, then add TTL jitter | Origin request-rate distribution over time | Jitter spreads refresh work rather than removing it. A lower peak with similar total work demonstrates load shaping, not free capacity. |

Result interpretation should compare origin work, tail latency, and stale-data behavior together. A higher cache hit ratio alone does not explain whether the system is safer during expiry or failure.

## Writing Style

Each cache topic should include:

- An easy-to-understand business story.
- A minimal reproducible model.
- Observed behavior.
- Common solutions.
- The costs and boundaries of those solutions.
