# Cache penetration

Suppose a product API caches records returned by the database but does not cache "product not found." A client repeatedly requests deleted IDs, or an attacker sends a stream of random IDs that never existed. Every request misses the cache and reaches the database even though the answer remains absent.

This is cache penetration: requests for nonexistent data pass through the cache because ordinary value caching has nothing to store.

## Two Different Missing-Key Workloads

The phrase "many nonexistent requests" hides an important variable: key reuse.

| Workload | Default shape | Engineering pressure |
| --- | --- | --- |
| `repeated` | 10,000 requests reuse 100 nonexistent keys. | Can the cache remember a stable negative answer? |
| `unique` | 10,000 requests use 10,000 distinct nonexistent keys. | Can protection reject never-before-seen invalid keys without growing one entry per request? |

A solution that performs well on repeated typo traffic may perform poorly against a high-cardinality scan.

## Strategies

| Strategy | Core behavior | Main tradeoff |
| --- | --- | --- |
| `none` | Every missing key reaches the origin. | No extra state, but no protection. |
| `negative` | Store a marker after the origin confirms absence. | Absorbs repeated misses, but consumes cache space and can temporarily hide newly created data. |
| `bloom-4` | Bloom Filter with 4 bits per valid key. | Small filter with a relatively high false-positive rate. |
| `bloom-8` | Bloom Filter with 8 bits per valid key. | More memory for fewer false positives. |
| `bloom-12` | Bloom Filter with 12 bits per valid key. | Still more memory for a lower false-positive rate. |
| `bloom-8+negative` | Reject definite misses with Bloom, then cache false-positive misses. | Combines complementary protections, but also combines their lifecycle complexity. |

A Bloom Filter can say "definitely absent" or "possibly present." A false positive sends a nonexistent key to the origin; a correctly implemented filter must not reject a key that was inserted into it.

## Experiment Model

The runnable Go experiment is in [`benchmark/`](benchmark/). It:

- Defines 100,000 valid integer keys and inserts them into each Bloom Filter.
- Sends only nonexistent keys so penetration behavior is isolated from normal cache hits.
- Uses deterministic integer hashing and request sequences.
- Counts origin lookups instead of sleeping or connecting to a database.
- Converts lookup counts into modeled work using an explicit assumed cost.

The default matrix is:

| Variable | Value |
| --- | ---: |
| Valid keys represented by Bloom | 100,000 |
| Requests per workload | 10,000 |
| Distinct keys in repeated workload | 100 |
| Distinct keys in unique workload | 10,000 |
| Assumed origin cost | 5 ms per lookup |

Run it with:

```bash
cd topics/cache/cache-penetration/benchmark
go test ./...
go run .
```

Change the cardinalities and cost model with flags:

```bash
go run . \
  -valid-keys=1000000 \
  -requests=100000 \
  -repeated-keys=1000 \
  -origin-cost=10ms
```

A local default run is recorded in [`result/2026-09-02-darwin-arm64.md`](result/2026-09-02-darwin-arm64.md).

## What To Observe

- `Origin calls`: nonexistent requests that still reach the origin.
- `Avoided origin`: request share rejected or answered by protective state.
- `Bloom false positives`: request share that passes the filter despite being absent.
- `Negative hits`: requests answered by an existing negative marker.
- `Negative entries`: distinct absent keys retained by the negative cache.
- `Bloom memory`: exact size of the filter bit array, excluding small Go object overhead.
- `Modeled origin work`: origin calls multiplied by the configured per-call cost; this is not measured wall-clock time.

## Experiment And Result Interpretation

The default run is recorded in [`result/2026-09-02-darwin-arm64.md`](result/2026-09-02-darwin-arm64.md). Read the `repeated` and `unique` halves separately, because the same strategy can behave very differently in each.

| Change | Observe in the local run | Interpretation |
| --- | --- | --- |
| Reuse 100 nonexistent keys with negative caching | Origin calls fell from 10,000 to 100, followed by 9,900 `Negative hits`, with 100 negative entries. | A negative entry amortizes its first origin lookup only when the same key is requested again before that entry expires. |
| Make all 10,000 nonexistent keys unique | Negative caching still made 10,000 origin calls and retained 10,000 entries. | Negative caching does not protect the first request for each key; high-cardinality input turns it into memory pressure. |
| Raise Bloom memory from 4 to 12 bits per valid key on the unique workload | Origin calls fell from 1,445 to 32 and observed false positives from 14.45% to 0.32%, at 48.8 KiB, 97.7 KiB, and 146.5 KiB. | Bloom memory controls a probability tradeoff, not a binary enabled/disabled property. |
| Combine Bloom and negative caching on repeated misses | Origin calls fell from 100 (`bloom-8`) to 1, absorbed by 99 negative hits from one marker. | Bloom rejects definite misses; negative markers absorb the repeated false positives that remain. |

The two mechanisms cover different request shapes. Negative caching wins when absence repeats, because it only pays off on the second request for the same key. Bloom wins when the valid key set is known and misses are high-cardinality, because it rejects definite absent keys before they reach any origin or per-request state.

### Reading The Modeled Origin Work

Every timing in this table is derived, not measured: `Origin calls × 5 ms`, the assumed per-lookup cost. That makes the seconds column useful for comparing strategies within the model and useless as a latency prediction. `none` shows 50s because it makes 10,000 calls; `bloom-12` shows 0s on the repeated workload because it made zero calls. Read it as a work budget, and read the call count as the primary number, since the seconds column is just that count scaled by a constant.

The wait time a user experiences is a different quantity and is not in this table at all. Ten thousand origin calls against a system with, say, 100 concurrent lookup slots and 5 ms per lookup is roughly 0.5 s of aggregate work, not 50 s of user-visible latency. The model deliberately measures offered work rather than queueing, which is the right choice for choosing a protection strategy and the wrong one for predicting p99.

The gap between the two Bloom configurations is where the derived column earns its place, because it shows the false-positive rate turning into real traffic. On the `unique` workload, `bloom-4` makes 1,445 calls and `bloom-8` makes 205 — 7 times fewer, straight from the false-positive rate dropping from 14.45% to 2.05%. Going from `bloom-8` to `bloom-12` cuts calls from 205 to 32, another 6.4x, for 50% more memory, 97.7 KiB to 146.5 KiB. Read the memory column against the call column and the diminishing character is clear: the first step buys more absolute protection per byte than the last, which is what a logarithmic false-positive curve looks like when the input set is fixed at 100,000 keys.

Watch what happens when the key set is not fixed. Every figure here assumes 100,000 valid keys and computes bits-per-key from that. If the valid set grew to 10 million, the same configured bits-per-key would require 100 times the memory, and a filter sized for the smaller set would saturate and approach a 100% false-positive rate — at which point it would pass nearly every request through and `bloom-12` would behave like `none`. Bloom filters do not degrade gracefully with underestimation; the memory number is the load-bearing one.

Finally, note what the gap between `repeated` and `unique` costs each strategy. On `repeated`, negative caching reduces 10,000 calls to 100 and holds 100 entries. On `unique` it makes all 10,000 calls and holds 10,000 entries — it did no useful work and consumed the most memory of any strategy in the table. That is the same strategy, the same code, and the same request count; only the key distribution changed. The 100x difference in entry count is the reason the two workloads are separated in this experiment rather than averaged.

## Source And Pseudocode Walkthrough

The complete model is [`benchmark/main.go`](benchmark/main.go). The two workloads differ only in how absent keys are generated:

```go
repeated.keys[i] = uint64(validKeys + i%repeatedKeys)
unique.keys[i] = uint64(validKeys + i)
```

`repeated` cycles through 100 keys, so each absent key returns 100 times; `unique` advances every request and never repeats. Every generated key is greater than or equal to `validKeys`, so all requests are guaranteed to be absent from the validity filter.

`newBloomFilter` sizes the bit array and derives the hash count from the bits-per-item setting:

```go
size := uint64(itemCount * bitsPerItem)
words := (size + 63) / 64
hashes := uint64(math.Round(float64(bitsPerItem) * math.Ln2))
```

`add` and `mightContain` use double hashing, `(h1 + i*h2) % size`, to probe `hashes` positions. A lookup returns `false` as soon as one probed bit is unset, which is the "definitely absent" path that the `Avoided origin` column counts.

The request loop in `run` fixes the protection order:

```go
if !filter.mightContain(key) {
	r.bloomRejected++
	continue
}
r.bloomFalsePos++
if _, ok := negative[key]; ok {
	r.negativeHits++
	continue
}
r.originCalls++
if negative != nil {
	negative[key] = struct{}{}
}
```

A Bloom rejection avoids the origin entirely. Otherwise the key counts as a possible false positive and may still be absorbed by a marker created earlier. Only after both checks does the request become an origin call and, if negative caching is enabled, create a marker. This order explains the `bloom-8+negative` row: the 8-bit filter passed 100 requests, the first created the marker, and the remaining 99 became negative hits. `modeledOriginWork` is just `originCalls * originCost`; no origin is executed, so treat the work column as arithmetic, not wall-clock time.

## Why It Happens

Negative caching records knowledge learned from the origin:

```text
first request for missing key -> origin -> store absent marker
later request for same key    -> absent marker -> no origin
```

Its benefit therefore depends on repetition. For one-time random keys, each request pays the origin cost before creating state that may never be read again. A maximum negative-cache size, short TTL, admission policy, and input validation can be as important as the marker itself.

A Bloom Filter represents the known valid set in a compact bit array. Inserting a key sets several bit positions. A lookup rejected by any unset position is definitely absent. If all positions are set, the key may exist, but unrelated inserted keys may have set those bits by coincidence.

For an approximately optimal number of hashes, the false-positive probability is roughly:

```text
p ~= (0.6185)^(bits per item)
```

That predicts about 14.6%, 2.1%, and 0.3% for 4, 8, and 12 bits per item. Local observations should approach those rates with enough independently distributed missing keys. A small repeated key set can land above or below them because requests repeatedly sample the same filter outcomes.

## Boundaries

- The experiment contains only missing-key requests. Real capacity planning must include valid traffic and its cache hit ratio.
- Origin work is calculated from an assumed fixed cost. Databases may become slower as misses increase, so real elapsed cost is often nonlinear.
- Negative entries have no TTL in this finite experiment. Production markers need an expiry based on how quickly absent data can become valid.
- `Negative entries` counts logical entries, not their allocator, key, metadata, and eviction overhead.
- A standard Bloom Filter cannot remove keys cleanly. Rebuilds, versioning, or a counting variant may be needed as the valid set changes.
- Newly created valid keys must reach the filter before it is authoritative. Rejecting them due to a stale filter is a false negative at the system level even if the Bloom implementation itself has no false negatives for inserted keys.
- Bloom Filters are suitable only when the valid domain can be populated and updated. They are not a general replacement for authentication, authorization, rate limiting, or input validation.

## Common Misconceptions

- Negative caching does not automatically stop random high-cardinality attacks; it only helps after a key repeats.
- Bloom Filter false positives do not return wrong data. They permit some misses to continue to the cache or origin.
- Observing zero false positives in one finite sample does not mean the configured filter has a zero false-positive probability.
- More Bloom memory lowers false positives but does not solve synchronization with newly created or deleted records.
- Caching every invalid input can itself become a memory-exhaustion path.

## Small Conclusion

Negative caching is effective when absent keys repeat and their absence may be remembered safely. Bloom Filters are effective when a reasonably stable valid-key set is available and high-cardinality misses must be rejected before the origin. Their combination can handle repeated Bloom false positives, but only with explicit memory, expiry, and synchronization policies.
