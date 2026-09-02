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

| Change | Observe | Interpretation |
| --- | --- | --- |
| Raise concurrency with `naive` while keeping origin latency fixed | Origin calls and peak origin concurrency rise toward the burst size. | Cache-aside does not coordinate simultaneous misses; the origin delay gives more requests time to join the miss window. |
| Replace `naive` with `singleflight` | Origin calls and peak concurrency stay at one, while request latency remains close to origin latency. | Request coalescing bounds duplicate work but turns the loader into a shared dependency for all waiters. |
| Replace blocking refresh with `swr` | Origin work stays at one and request latency falls, while stale responses reach 100% for this expiry wave. | SWR moves the tradeoff from latency and origin pressure to bounded staleness. |
| Increase origin latency | The waiting time for `naive` and `singleflight` grows with it. | Coalescing changes the amount of work, not the duration of the one required origin load. |

Read these signals together. A strategy that makes only one origin call is not automatically acceptable if all callers wait too long, and a low-latency stale response is not automatically acceptable for data requiring read-after-write freshness.

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
