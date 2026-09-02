# Cache avalanche

Suppose a service warms 1,000 popular catalog entries during deployment and gives every entry the same 30-minute TTL. The cache works well until those entries reach the same expiry boundary. Normal traffic then discovers many expired keys in a short interval and sends their refresh work to the origin together.

This is a cache avalanche: load from many keys becomes correlated in time. It differs from [cache breakdown](../cache-breakdown/), where many requests duplicate work for one hot key.

## Why Per-Key Coalescing Is Not Enough

Request coalescing can ensure that one expired key creates only one origin load:

```text
key A: 100 misses -> 1 origin load
```

It cannot combine loads for different values:

```text
keys A through Z expire -> 26 origin loads
```

This experiment therefore coalesces requests within every key before comparing expiry schedules. That controls the cache-breakdown problem so the remaining signal comes from cross-key synchronization.

## Expiry Schedules

| Schedule | Expiry offset | Practical meaning |
| --- | --- | --- |
| `aligned` | Every key uses offset zero. | Bulk population assigns the same TTL at nearly the same time. |
| `jittered` | Each key receives a deterministic random offset within the spread window. | Normal TTL plus random jitter. |
| `staggered` | Keys are evenly distributed across the spread window. | Controlled refresh batches or deliberately staggered warmup. |

Random jitter is operationally simple but does not guarantee perfectly even buckets. Deliberate staggering is smoother in this controlled model, but needs scheduling and ownership that may be harder to operate.

## Experiment Model

The runnable Go model is in [`benchmark/`](benchmark/). It continuously reads every key at a fixed interval. A key refresh starts only after a normal cache read observes that key as expired; the experiment does not invoke refreshes directly from their configured expiry times.

The default variables are:

| Variable | Value |
| --- | ---: |
| Independently cached hot keys | 1,000 |
| Time before first expiry | 100 ms |
| Jitter or stagger window | 500 ms |
| Read interval for every key | 10 ms |
| Fixed origin latency | 20 ms |
| Origin capacity | Unlimited and 50 concurrent loads |
| Repeats | 3 per case |

An unlimited origin reveals the offered concurrency. Capacity 50 represents a downstream connection or worker limit and reveals the queue created when offered load exceeds that limit.

Run the experiment with:

```bash
cd topics/cache/cache-avalanche/benchmark
go test ./...
go run .
```

The matrix is configurable:

```bash
go run . \
  -keys=2000 \
  -base-ttl=200ms \
  -spread-window=1s \
  -request-interval=20ms \
  -origin-latency=50ms \
  -origin-capacity=0,100 \
  -repeats=5
```

A local default run is recorded in [`result/2026-09-02-darwin-arm64.md`](result/2026-09-02-darwin-arm64.md).

## What To Observe

- `Origin calls`: total refresh work. All schedules should eventually refresh the same number of keys.
- `Max attempts/bucket`: the busiest origin-attempt bucket, using the request interval as bucket width.
- `Attempt span`: elapsed time between the first and last origin refresh attempt.
- `Peak active`: maximum origin loads executing concurrently.
- `Peak queued`: maximum loaders waiting for limited origin capacity.
- `P99 queue wait`: tail time spent waiting to enter the limited origin.

The primary comparison is temporal shape, not cache hit ratio. Jitter should spread the same total work over a wider interval, lowering peaks when the spread window is large enough relative to key count, request frequency, origin latency, and origin capacity.

## Experiment And Result Interpretation

| Change | Observe | Interpretation |
| --- | --- | --- |
| Align all expiries | Origin attempts concentrate into one request bucket and active concurrency rises sharply. | Independent key refreshes become correlated because their TTL boundaries are correlated. |
| Add random TTL jitter | Attempts span approximately the configured jitter window and the busiest bucket becomes smaller. | Jitter reshapes when refresh work happens; random clustering means individual buckets can still be uneven. |
| Stagger expiries evenly | The busiest bucket becomes more predictable than random jitter in this controlled setup. | Explicit scheduling can smooth work further, at the cost of orchestration complexity. |
| Limit origin concurrency | Aligned expiry creates a large queue and tail queue wait, while spread schedules reduce both. | A capacity limit converts excess concurrency into waiting; it does not remove the offered work. |

## Why It Happens

TTL is not just a freshness control. It also schedules future origin work. Assigning the same TTL at the same time correlates that future work, even when normal request traffic and per-key cache logic are otherwise healthy.

With 1,000 keys, a 20 ms origin latency, and no capacity limit, an aligned expiry can make nearly 1,000 loads overlap. If origin capacity is 50, only 50 can execute while the rest queue in batches. The last batch cannot start until earlier batches release capacity, increasing request latency and consuming deadlines or worker resources.

Adding a random offset over 500 ms does not avoid the 1,000 required refreshes. It lowers the arrival rate of those refreshes so the origin has time to finish earlier work before later keys expire. The useful condition is approximately:

```text
refresh arrival rate < sustainable origin completion rate
```

If the jitter window is too narrow or origin latency rises, jittered refresh traffic can still exceed capacity.

## Boundaries

- Reads are intentionally frequent and uniform, ensuring every key is refreshed soon after expiry. Real traffic may delay cold-key refreshes and concentrate hot-key effects differently.
- The fake origin has fixed latency and a simple concurrency semaphore. Real systems have connection pools, queue limits, lock contention, retries, and latency that often worsens under load.
- All origin calls succeed. Retry synchronization after an outage can create another avalanche and needs a separate experiment.
- The experiment performs lazy refresh on reads. Proactive refresh introduces scheduler, ownership, and failure-recovery tradeoffs.
- Random offsets use a fixed seed for reproducibility. Production processes should avoid accidentally assigning identical pseudo-random sequences across instances.
- Very long jitter changes freshness semantics. TTL and jitter ranges must respect how stale the underlying data may become.

## Common Misconceptions

- TTL jitter does not reduce total refresh work; it redistributes that work over time.
- Per-key singleflight prevents one-key duplication, not simultaneous loads for many different keys.
- An origin connection limit does not solve the avalanche. It protects active capacity by moving excess work into a queue that still needs bounds and timeouts.
- Random jitter does not produce a perfectly flat schedule. It reduces correlation probabilistically.
- Cache hit ratio averaged over minutes can hide a severe one-second expiry burst.

## Small Conclusion

When many independently useful cache entries receive correlated expiry times, their refresh work can exceed origin capacity even if every key uses request coalescing. TTL jitter and staggered refresh are load-shaping tools: they lower temporal peaks when their spread window is wide enough, but they do not eliminate the underlying origin work.
