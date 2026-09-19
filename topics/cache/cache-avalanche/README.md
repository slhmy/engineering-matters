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

The default run is recorded in [`result/2026-09-02-darwin-arm64.md`](result/2026-09-02-darwin-arm64.md). The first three rows use an unlimited origin, so they show offered concurrency; the last three use capacity 50, so excess work becomes a queue.

| Change | Observe in the local run | Interpretation |
| --- | --- | --- |
| Align all 1,000 expiries (unlimited origin) | Origin calls stayed at 1,000, but all attempts landed in one 10 ms bucket and `Peak active` reached 1,000 over a 1.122 ms span. | Independent key refreshes become correlated because their TTL boundaries are correlated. |
| Add random TTL jitter (unlimited) | `Max attempts/bucket` fell to 31, attempts spread over 497.204 ms, and `Peak active` fell to 69.3. | Jitter reshapes when refresh work happens; identical total work, spread over a wider interval. |
| Stagger expiries evenly (unlimited) | `Max attempts/bucket` fell to 23.7 over a 499.556 ms span. | An even schedule is slightly smoother than random jitter in this controlled setup, at the cost of orchestration. |
| Limit the origin to 50 concurrent loads, aligned | `Peak queued` reached 950 and `P99 queue wait` reached 391.43 ms. | The limit does not remove offered work; it converts 1,000 simultaneous loads into 20 serialized batches of 50. |
| Keep capacity 50, add jitter | `Peak queued` fell to 17 and `P99 queue wait` to 4.441 ms. | Spreading arrivals keeps each 10 ms window small enough for the origin to drain earlier loads. |
| Keep capacity 50, stagger | `Peak queued` fell to 13 and `P99 queue wait` to 1.87 ms. | Even arrivals leave the least residual queue because 20 ms loads overlap fewer 10 ms request ticks. |

Every row makes exactly 1,000 origin calls. Read the `Origin calls` column first: if it is unchanged, the schedule only moved work in time, it did not remove any. Then read `Max attempts/bucket` with `Peak queued` for the same case to see offered load versus actual queuing.

## Source And Pseudocode Walkthrough

The complete model is [`benchmark/main.go`](benchmark/main.go). The schedule is decided before any request runs:

```go
case aligned:
	return offsets
case jittered:
	rng := rand.New(rand.NewSource(seed))
	for i := range offsets {
		offsets[i] = time.Duration(rng.Int63n(int64(window) + 1))
	}
case staggered:
	for i := range offsets {
		offsets[i] = time.Duration(i) * window / time.Duration(keys-1)
	}
```

Each key receives `started.Add(baseTTL + offsets[i])`. Aligned leaves every offset at zero, so all 1,000 keys expire at the same instant and, because the read loop ticks every 10 ms, their refresh attempts fall into a single `Max attempts/bucket` bucket. Jitter draws each offset independently with the fixed `-seed`; staggered places keys at even multiples of `window / (keys-1)`.

`cacheEntry.get` coalesces per key before the schedule effect is measured:

```go
e.mu.RLock()
fresh := time.Now().Before(e.expiresAt)
e.mu.RUnlock()
if fresh {
	return
}

e.loadMu.Lock()
if call := e.load; call != nil {
	e.loadMu.Unlock()
	<-call.done
	return
}
```

Only the first reader of an expired key reaches `o.load`; later readers wait on `call.done`. This is why every schedule records the same 1,000 origin calls: the experiment changes *when* each key becomes stale, not how many origin loads one stale key requires.

`origin.load` records the attempt bucket and enforces capacity with a semaphore:

```go
o.recordAttempt(attemptedAt)
if o.sem != nil {
	select {
	case o.sem <- struct{}{}:
	default:
		waiting := o.waiting.Add(1)
		updatePeak(&o.peakWaiting, waiting)
		o.sem <- struct{}{}
	}
}
```

`recordAttempt` places each call into a `request-interval`-wide bucket, which produces the `Max attempts/bucket` and `Attempt span` columns. The default branch of the semaphore counts queueing, which is how the aligned capacity-50 case reports `Peak queued = 950`. `run` later sorts `queueWaits` and passes it to `percentile` for the `P99 queue wait` column. Lowering the bucketed attempt rate therefore lowers the queue; lowering total calls would be the only thing that removes the work.

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
