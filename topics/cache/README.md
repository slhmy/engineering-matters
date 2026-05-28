# Cache

The cache category records common cache behaviors, risks, and practices in backend systems.

## Planned Topics

- Cache penetration: requested data does not exist, so requests keep reaching the database.
- Cache breakdown: a hot key expires and many requests fall back to the origin at the same time.
- Cache avalanche: many keys expire together and put sudden pressure on downstream systems.
- Hot keys: a small number of keys receive extremely high traffic.
- Cache consistency: timing problems between writing the database and deleting or updating the cache.
- Local cache vs distributed cache: tradeoffs among latency, capacity, and consistency.

## Writing Style

Each cache topic should include:

- An easy-to-understand business story.
- A minimal reproducible model.
- Observed behavior.
- Common solutions.
- The costs and boundaries of those solutions.
