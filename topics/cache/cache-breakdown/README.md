# Cache breakdown

A product-detail endpoint normally serves a hot product from cache. When that key expires, hundreds of requests may discover the miss before the first database query finishes. One expired key has then become many concurrent origin requests.

This behavior is commonly called cache breakdown in Chinese engineering discussions and cache stampede more broadly. The important condition is not merely a cache miss: many requests for the same key miss during the same origin-load window.

## The Intuitive Implementation

A basic cache-aside read path looks like this:

```text
read cache
  -> hit: return value
  -> miss or expired: read origin, populate cache, return value
```

The logic is correct for one request. Under concurrency, every request can start the expensive origin read before any request has repopulated the cache.

## Strategies

| Strategy | Behavior after the hot key expires | Main tradeoff |
| --- | --- | --- |
| `naive` | Every request that observes the expired entry loads from origin. | Fresh responses, but duplicate origin work is unbounded within the miss window. |
| `singleflight` | One request loads from origin while other requests wait for its result. | Removes duplicate work, but waiting requests inherit the load latency and failure. |
| `swr` | Requests immediately receive the stale value while one background refresh runs. | Low response latency and bounded origin work, but stale data is deliberately served. |

`singleflight` here describes request coalescing, not a requirement to use Go's `golang.org/x/sync/singleflight` package. The experiment uses a small local implementation so the coordination behavior is visible.

## Experiment Model

The runnable model is in [`benchmark/`](benchmark/). It uses:

- One cache entry seeded as already expired, avoiding real-time TTL waits.
- A fake origin with configurable, fixed latency.
- A synchronized burst of goroutines requesting the same key.
- A fresh TTL long enough that the refreshed entry cannot expire during a wave.
- A new cache and origin for every wave, so cases do not share state.

The default matrix changes one major pressure at a time:

| Variable | Values |
| --- | --- |
| Strategy | `naive`, `singleflight`, `swr` |
| Concurrent requests | 1, 10, 100, 1,000 |
| Origin latency | 10 ms, 100 ms |
| Repeated expiry waves | 5 |

Run it with:

```bash
cd topics/cache/cache-breakdown/benchmark
go test ./...
go run .
```

Flags can reduce or extend the matrix:

```bash
go run . -concurrency=10,100 -origin-latency=20ms,200ms -repeats=10
```

The command emits a Markdown table. A local default run is recorded in [`result/2026-09-02-darwin-arm64.md`](result/2026-09-02-darwin-arm64.md).

## What To Observe

- `Origin calls/wave`: how much duplicate origin work one expiry event creates.
- `Peak origin concurrency`: the instantaneous pressure placed on the origin.
- `P50`, `P95`, and `P99`: whether callers wait for the origin or receive an immediately available stale value.
- `Stale responses`: the freshness cost of avoiding that wait.
- `Requests/s`: response completion rate inside this controlled model, not production capacity.

The experiment waits for SWR's background refresh before collecting origin metrics, but does not include that background work in request latency. That is intentional: callers have already received the stale response.

## Experiment And Result Interpretation

The default run is recorded in [`result/2026-09-02-darwin-arm64.md`](result/2026-09-02-darwin-arm64.md). The clearest contrast is at concurrency 1,000.

| Change | Observe in the local run | Interpretation |
| --- | --- | --- |
| Raise concurrency with `naive` while keeping origin latency fixed | At concurrency 1,000 and a 10 ms origin, `naive` made 1,000 origin calls and reached `Peak origin concurrency = 1000`; P99 was 12.059 ms. | Cache-aside does not coordinate simultaneous misses; the origin delay gives more requests time to join the miss window. |
| Replace `naive` with `singleflight` | Origin calls and peak concurrency dropped to 1, while P99 stayed at 12.266 ms. | Request coalescing bounds duplicate work but turns the loader into a shared dependency for all waiters. |
| Replace blocking refresh with `swr` | Origin work stayed at 1 and P99 fell to 1 us, while `Stale responses` reached 100%. | SWR moves the tradeoff from latency and origin pressure to bounded staleness. |
| Increase origin latency from 10 ms to 100 ms at concurrency 1,000 | `naive` P99 rose to 104.452 ms and `singleflight` P99 to 102.829 ms, but their origin-call counts did not change. | Coalescing changes the amount of work, not the duration of the one required origin load. |

The `Origin calls/wave` column is the primary signal, not `Requests/s`. At concurrency 1,000, `naive` generated 1,000 times the origin work of the other two strategies, `singleflight` removed that duplication but kept P99 near the full origin latency, and `swr` removed the wait only by serving the stale value to all 1,000 requests. Read these signals together: a strategy that makes only one origin call is not automatically acceptable if waiters still block, and a low-latency stale response is not automatically acceptable for data requiring read-after-write freshness.

### Reading The Latencies

The three strategies produce three different latency floors, and each one is explained by a different constraint. Holding the 10 ms origin latency fixed:

| Concurrency | `naive` P99 | `singleflight` P99 | `swr` P99 | Origin calls |
| ---: | ---: | ---: | ---: | --- |
| 1 | 12.156 ms | 12.159 ms | 11 µs | 1 / 1 / 1 |
| 10 | 12.114 ms | 11.987 ms | 6 µs | 10 / 1 / 1 |
| 100 | 12.203 ms | 12.136 ms | 917 ns | 100 / 1 / 1 |
| 1,000 | 12.059 ms | 12.266 ms | 1 µs | 1,000 / 1 / 1 |

**`naive` and `singleflight` sit at the same latency floor, and it is the origin's.** Every value in those two columns is between 11.9 and 12.3 ms regardless of concurrency, because both strategies make the caller wait for a real origin load, and the origin takes 10 ms. The residual ~2 ms above the configured latency is `time.Sleep` overshoot on this host, not a property of either strategy.

That identical floor is the finding. `singleflight` cut origin work by a factor of 1,000 at concurrency 1,000 — from 1,000 calls to 1 — and changed P99 by 0.2 ms, inside the spread of the other rows. Duplicate work was not the thing delaying callers. Each caller was waiting on its own required load, and coalescing only decided how many copies of that work the origin performed. A strategy that protects the origin does not thereby make requests faster.

**`swr` sits at a completely different floor, and it is not the origin's at all.** 11 µs at concurrency 1, 1 µs at 1,000 — three to four orders of magnitude below the other two, scaling the wrong way with concurrency and improving as more requests arrive. That is the signature of a path that never touches the origin: the measured request reads the existing stale value. The number is an in-memory map read plus goroutine scheduling, not a service response time, and it should not be compared to the other columns as if all three measured the same thing. What it does establish is where the latency goes. Removing the origin call from the request path removes essentially all of the latency, which confirms that the origin call was the entire cost in the other two strategies.

**The 100 ms origin case isolates the residual the floor hides.** At concurrency 1,000, `naive` P99 is 104.452 ms and `singleflight` is 102.829 ms — a 1.6 ms gap that the 10 ms rows are too noisy to show. With a slower origin there is more time between the first and last duplicate load, so the extra concurrent work in the `naive` case becomes visible as slightly worse tail latency. The gap is real but small, and it is the only place in the table where the strategies' latency differs at all. Treat it as evidence about scheduling contention, not as the reason to choose coalescing; the reason is the 1,000 versus 1 origin calls, which matters for the origin's capacity and not for these callers' latency.

## Source And Pseudocode Walkthrough

The complete implementation is [`benchmark/main.go`](benchmark/main.go). Its central branch is equivalent to:

```go
entry, ok := cache.lookup()
if ok && entry.isFresh() {
	return entry.value
}

switch strategy {
case naive:
	return loadOriginAndStore()
case singleflight:
	return loadOnce()
case swr:
	if ok {
		refreshInBackgroundOnce()
		return entry.value
	}
	return loadOnce()
}
```

All three strategies share the same fresh-hit path. Their behavior diverges only after expiry: `naive` provides no coordination, `singleflight` blocks on shared work, and SWR can return only when an old value still exists. A cold miss therefore cannot use the stale fast path.

The local singleflight implementation publishes one in-flight call and gives waiters its completion channel:

```text
lock load state
if a call exists:
    unlock, wait for call.done, return call.value
recheck cache while coordinated
publish a new call, then unlock

value = origin.load()
store value
clear the call and close call.done
```

The second cache check matters because another loader may have refreshed the value before this request acquired `loadMu`. Publishing the call before invoking the origin ensures later misses join the same work. Closing `done` releases all waiters only after the value has been stored.

SWR uses a separate `refreshing` flag to admit one background goroutine. Other callers see the flag, skip starting another refresh, and immediately return the stale entry. This explains both observed signals: one origin call and near-zero request wait, purchased with stale responses.

## Why It Happens

An expired cache entry does not serialize readers. If 100 requests arrive during a 100 ms origin query, the naive read path can start 100 copies of that query. A database connection pool may cap actual database concurrency, but that changes the failure shape into queued requests and pool exhaustion rather than removing duplicate work.

Request coalescing creates one in-flight load per logical key. Requests for the same key share its result; unrelated keys should still load independently in a real implementation. This protects the origin but can create a large waiter set, so implementations need timeout, cancellation, panic handling, and error policy.

SWR separates cache freshness from cache usability. An expired value remains usable for a bounded stale interval while one refresh runs. It avoids making user requests wait for the refresh, but requires a product decision about how stale a value may be and what happens after repeated refresh failures.

## Boundaries

- The fake origin isolates coordination behavior; it does not reproduce database locks, connection pools, network queues, retries, or variable latency.
- Every wave targets one key. Multiple simultaneous hot keys require per-key coordination and can still overload the origin in aggregate.
- This model starts with a stale value. On a cold miss, SWR has nothing to serve and falls back to a blocking coalesced load.
- The local singleflight implementation has no timeout or cancellation policy. Production code must decide whether disconnected waiters cancel shared work.
- The SWR implementation has no maximum stale age. Production systems should bound staleness and define behavior when refresh repeatedly fails.
- Very cheap origins may not justify coordination complexity. Measure origin capacity and the actual overlap window first.

## Common Misconceptions

- Adding a mutex around the whole cache is not required; coordination should usually be scoped by key so unrelated misses can proceed independently.
- Request coalescing does not make the origin faster. It reduces duplicate calls while callers still wait for one load.
- TTL jitter primarily addresses many keys expiring together. It does not prevent a single hot key from attracting concurrent misses when that key expires.
- A high steady-state hit ratio does not describe behavior at the exact expiry boundary.
- SWR is not free freshness. Its latency benefit comes from serving an older value.

## Small Conclusion

For a hot key with an origin load slower than the request inter-arrival time, an uncoordinated cache-aside miss can multiply origin work. Request coalescing bounds that work but preserves blocking latency; SWR can remove the blocking latency only when bounded stale reads are acceptable.
