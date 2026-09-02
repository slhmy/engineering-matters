# Go sync map

This topic uses a small experiment to compare several concurrent map strategies in Go: `map + sync.Mutex`, `map + sync.RWMutex`, `sync.Map`, a hand-written sharded map, and `orcaman/concurrent-map`.

## Problem Background

Suppose a service needs to maintain shared in-memory state:

- User sessions.
- Hot configuration.
- Local cache entries.
- Metric counters.
- Task states.

Multiple goroutines may read and modify this state at the same time. A plain `map` is not safe for concurrent reads and writes, so we need a concurrency-safe strategy.

The intuitive first choices are often:

- Protect a regular `map` with a lock.
- Replace it with `sync.Map`, because it looks like "the concurrent map."

The catch is that "concurrency-safe" only means the program will not crash because of concurrent map access. It does not mean the choice is faster, simpler, or more maintainable under every access pattern.

## Common Options

| Option | Core idea | Useful question |
| --- | --- | --- |
| `map + sync.Mutex` | All reads and writes share one exclusive lock. | Is the simplest solution good enough when the critical section is short and concurrency is low? |
| `map + sync.RWMutex` | Reads share a read lock; writes take an exclusive lock. | Does the read lock reduce waiting in read-heavy workloads? |
| `sync.Map` | The standard library concurrent map optimized for specific access patterns. | Does it help when keys are relatively stable and reads dominate writes? |
| Hand-written sharded map | Spread keys across multiple locks. | Does sharding reduce contention when keys are well distributed? |
| `orcaman/concurrent-map` | A third-party sharded map with 32 shards by default. | How does a maintained sharded-map library compare with a small local implementation? |

None of these options is universally better. They fit different access patterns.

## Mental Model

Think of a shared map as a public ledger.

- `Mutex` is like having one pen next to the ledger: anyone who reads or writes must take the pen first.
- `RWMutex` allows many people to read the ledger at the same time, but everyone waits when someone edits it.
- `sync.Map` adds special handling for read-heavy cases so commonly read entries can be seen faster, while writes and internal promotion still have their own costs.
- A sharded map splits the ledger across multiple counters, so different keys can queue at different places.

## Experiment Design

The benchmark lives here:

```text
topics/go/sync-map/benchmark/
```

Run it with:

```bash
cd topics/go/sync-map/benchmark
go test -bench=. -benchmem -benchtime=1s -cpu=1,4,8
```

The experiment compares eight implementations:

- `mutex`
- `rwmutex`
- `syncmap`
- `shard4`
- `shard8`
- `shard32`
- `shard128`
- `orcaman32`

The local sharded maps use the same hash function and differ only in shard count. `orcaman32` uses `github.com/orcaman/concurrent-map/v2` with an integer key and a custom sharding function, so it can be compared with the local `shard32` implementation without adding string-conversion cost.

It varies these factors:

- 99% reads, 1% writes.
- 90% reads, 10% writes.
- 50% reads, 50% writes.
- 10% reads, 90% writes.
- 100% writes on uniformly distributed stable keys.
- 1,000 stable keys.
- 4, 8, 32, and 128 shards for the local sharded-map implementation.
- Hot-key access.
- 90% writes on 10 hot keys.
- 100% writes on a single hot key.
- 50% reads and 50% writes on a single hot key.
- Inserting a new key on every write.

Observed metrics:

- Time per operation.
- Throughput.
- Memory allocation.
- Behavior under different concurrency levels.
- Lock contention under hot keys.

## How To Read The Results

This repository records local runs:

```text
topics/go/sync-map/result/2026-08-23-darwin-arm64.md
```

Do not read this kind of benchmark as a single "which row is fastest" ranking. Read the shape:

- With `-cpu=1`, there is little lock contention, so the overhead of extra mechanisms is easier to see.
- With `-cpu=8`, contention increases, and the differences among sharding, read/write locks, and `sync.Map` become more visible.
- As the write ratio rises, the read-sharing advantage of `RWMutex` weakens.
- When access concentrates on a few keys, a sharded map can still degrade into queues on a small number of shards.
- Increasing the shard count can reduce unrelated-key contention, but adds more locks and may not help when the key set or access pattern is small.
- A high write ratio alone does not imply high contention; uniformly distributed writes can still run in parallel.
- When every goroutine writes the same hot key, the local lock and allocation costs of `sync.Map` become visible.
- When the workload keeps inserting new keys, `sync.Map` is no longer only hitting its stable read path.

## Experiment And Result Interpretation

| Change | Observe | Interpretation |
| --- | --- | --- |
| Raise `-cpu` from 1 to 8 on stable, read-heavy keys | `sync.Map` and maps that permit parallel reads improve relative to one global exclusive lock. | Concurrency mechanisms pay overhead at low contention but can avoid serialization when independent operations overlap. |
| Increase the write ratio while keeping keys distributed | The advantage of `RWMutex` narrows, while sharding and `sync.Map` can still let unrelated keys progress independently. | Write percentage is not contention by itself; key distribution determines whether operations meet at the same synchronization point. |
| Concentrate writes on one hot key | Implementations converge toward serialized behavior; `syncmap` reached about 107.7 ns/op in the local 8-CPU hot-write run. | A concurrent data structure cannot parallelize conflicting updates to the same logical value. Shards only help when requests reach different shards. |
| Insert a new key on every write | `syncmap` reported 3 allocations per operation in the local run. | Stable-key lookup and continual growth exercise different internal paths; allocation and trie expansion become part of the cost. |

Do not select the globally fastest row. Match the result slice to the application's read/write ratio, key stability, key distribution, and concurrency level.

## Explanation

`sync.Map` is usually better suited to read-heavy workloads where keys are relatively stable and each key is written once but read many times. Its goal is not to replace every `map + lock` implementation; it targets the two common patterns described by the standard library documentation: write-once-read-many, and multiple goroutines reading or writing mostly disjoint key sets.

`map + RWMutex` is intuitive in read-heavy cases because readers can proceed concurrently. Once writes become more frequent, though, the write lock blocks new readers, and the read/write lock itself has management overhead.

`map + Mutex` is simple and often good enough when concurrency pressure is low or the critical section is tiny.

A sharded map can reduce contention on a single lock, but it adds implementation complexity and depends on a suitable hash function and shard count. A third-party library such as `orcaman/concurrent-map` can remove some maintenance burden, but it is still a sharded-map design rather than a universally better replacement for `sync.Map`.

## Source And Pseudocode Walkthrough

The benchmark uses Go 1.26.6. In this version, `sync.Map` is implemented with a concurrent hash trie. This is different from the `readOnly` and `dirty` dual-map implementation described by many older articles.

Before reading the implementation details, use this conceptual path:

```text
Load(key):
    hash key
    atomically follow one trie child per 4 hash bits
    if the leaf key matches, atomically read its value
    otherwise report missing

Store(key, value):
    hash key and follow the trie toward its leaf
    lock the local mutation node
    replace the matching entry, or install/expand nodes for a new key
    unlock the local node
```

This is not literal Go source; it highlights the synchronization boundary. A steady-state `Load` traverses atomic pointers without taking a mutex. Writes that reach different trie regions may lock different local nodes, while writes to one hot key converge on the same node and serialize. New keys can also allocate entries and expand branches, which connects directly to the benchmark's hot-key and new-key results.

### Public Wrapper

The public type is intentionally small. [`sync.Map`](https://github.com/golang/go/blob/go1.26.6/src/sync/map.go#L38-L54) delegates its operations to an internal generic map:

```go
type Map struct {
	_ noCopy
	m isync.HashTrieMap[any, any]
}

func (m *Map) Load(key any) (value any, ok bool) {
	return m.m.Load(key)
}

func (m *Map) Store(key, value any) {
	m.m.Store(key, value)
}
```

The public API still uses `any`, even though the internal implementation is generic. This preserves the existing API but means callers pay for interface keys and values, and usually need a type assertion after `Load`. The benchmark wrapper includes that assertion for `syncmap`.

### Core Data Structure

The important fields in [`HashTrieMap`](https://github.com/golang/go/blob/go1.26.6/src/internal/sync/hashtriemap.go#L21-L28) are:

```go
type HashTrieMap[K comparable, V any] struct {
	inited  atomic.Uint32
	initMu  Mutex
	root    atomic.Pointer[indirect[K, V]]
	keyHash hashFunc
	seed    uintptr
}
```

The trie contains two node forms. The following is simplified from the [node definitions](https://github.com/golang/go/blob/go1.26.6/src/internal/sync/hashtriemap.go#L530-L576):

```go
type indirect[K comparable, V any] struct {
	dead     atomic.Bool
	mu       Mutex
	parent   *indirect[K, V]
	children [16]atomic.Pointer[node[K, V]]
}

type entry[K comparable, V any] struct {
	overflow atomic.Pointer[entry[K, V]]
	key      K
	value    V
}
```

An `indirect` node is a branch in the trie. Its mutex protects mutations to that branch and to direct entry children; it is not a map-wide mutex. Each child pointer is atomic so readers can traverse a branch without acquiring `mu`.

An `entry` is a leaf containing one key and value. `overflow` links entries whose full hashes collide. A normal lookup follows the trie first and only scans this chain when keys have the same hash path.

The trie consumes four hash bits per level because each branch has 16 children:

```text
hash bits:  [63..60] [59..56] [55..52] ...
child index:    0         1         2
```

The source comments call 16 children the load-performance sweet spot: fewer children make the trie deeper, while 32 children add space for little additional read improvement. This is a separate choice from the 4, 8, 32, and 128 top-level shards in the hand-written benchmark map.

### Lazy Initialization

The zero value is usable because initialization happens on the first operation. [`initSlow`](https://github.com/golang/go/blob/go1.26.6/src/internal/sync/hashtriemap.go#L30-L55) takes `initMu`, checks the flag again, and then initializes:

- An empty root node.
- The runtime map hasher for the key type.
- The equality function needed by compare operations.
- A random hash seed.

The root and metadata are prepared before `inited.Store(1)` publishes the initialized state. Only the first operation may take this initialization lock; steady-state reads see `inited != 0` and continue directly.

### Load Path

The key part of [`Load`](https://github.com/golang/go/blob/go1.26.6/src/internal/sync/hashtriemap.go#L64-L82) is:

```go
hash := ht.keyHash(abi.NoEscape(unsafe.Pointer(&key)), ht.seed)
i := ht.root.Load()
hashShift := 8 * goarch.PtrSize
var zero V

for hashShift != 0 {
	hashShift -= 4
	n := i.children[(hash>>hashShift)&15].Load()
	if n == nil {
		return zero, false
	}
	if n.isEntry {
		return n.entry().lookup(key)
	}
	i = n.indirect()
}
```

The steps are:

1. Hash the key using Go's runtime map hasher and the map-specific seed.
2. Atomically load the root pointer.
3. Select one of 16 children from the next four hash bits.
4. Atomically load that child pointer.
5. Return immediately for a missing child, compare the key for an entry, or continue through another indirect node.

`abi.NoEscape` prevents passing the key pointer to the hasher from unnecessarily making the key escape to the heap. The returned zero value is also normally optimized without a heap allocation.

After initialization, `Load` does not acquire a mutex. Readers may observe either the old or new immutable entry around a concurrent replacement, but never a partially initialized entry. This explains why stable reads scale from one CPU to multiple CPUs without a shared lock becoming a queue.

This read path is better described as mutex-free than as universally cost-free. It still performs hashing, atomic pointer loads, pointer chasing, interface handling, and key comparison. Those costs are visible in the `-cpu=1` baseline, where a regular map protected by an uncontended lock can be cheaper.

### Store And Swap Path

[`Store`](https://github.com/golang/go/blob/go1.26.6/src/internal/sync/hashtriemap.go#L198-L201) delegates to [`Swap`](https://github.com/golang/go/blob/go1.26.6/src/internal/sync/hashtriemap.go#L203-L274). The write algorithm uses optimistic traversal followed by validation under a local lock:

```text
traverse atomically to a candidate slot
  -> lock the parent indirect node
  -> reload the slot
  -> verify that the parent is not dead
  -> update, insert, or restart
```

The slot must be reloaded after locking because another writer may have changed the branch between the optimistic traversal and `mu.Lock`. The `dead` flag handles a parent node that was detached while this goroutine was traversing it. If either check fails, the writer unlocks and starts again from the current root.

For an existing key, `entry.swap` creates a replacement entry and the writer publishes it with `slot.Store`. Readers that already loaded the old pointer can finish reading the old entry, while later readers see the replacement. Go's garbage collector eventually reclaims the old entry after no reader can reach it.

This copy-and-publish update has two consequences:

- Readers do not need to coordinate with an in-place value mutation.
- Repeated writes create allocation and garbage-collection work, which appears in the benchmark as non-zero `B/op` and `allocs/op` for `syncmap`.

### New-Key Insertion And Trie Expansion

If the candidate slot is empty, the writer creates an entry and atomically stores it. If the slot contains a different key, [`expand`](https://github.com/golang/go/blob/go1.26.6/src/internal/sync/hashtriemap.go#L165-L195) compares their hashes:

- Equal full hashes use the `overflow` chain.
- Different hashes create indirect nodes until one four-bit group selects different children.

The complete new subtree is built before its top pointer is stored into the existing trie. Publishing the subtree last prevents readers from seeing an intermediate state where the old key has disappeared but the new subtree is incomplete.

This path explains why continuously inserting new keys costs more than replacing stable keys. It may allocate an entry, one or more indirect nodes, and collision-chain state, in addition to increasing the live map size.

### Delete And Structural Cleanup

Delete operations first find the entry, lock its parent node, and validate the slot using the same retry pattern as writes. [`LoadAndDelete`](https://github.com/golang/go/blob/go1.26.6/src/internal/sync/hashtriemap.go#L307-L355) then either replaces an overflow chain or stores `nil` into the child slot.

If an indirect node becomes empty, deletion walks toward the root:

```text
lock parent
  -> mark empty child node as dead
  -> unlink it from the parent
  -> continue while the parent is empty
```

Marking the detached node `dead` is what makes concurrent writers that reached the stale node retry instead of publishing into a branch no longer reachable from the root. Readers that already hold the old pointer can still finish safely.

### Range And Clear

[`Range`](https://github.com/golang/go/blob/go1.26.6/src/internal/sync/hashtriemap.go#L473-L518) recursively follows atomic child pointers without locking the whole map. It therefore does not return a consistent snapshot: concurrent updates may cause different keys to reflect different points in time.

[`Clear`](https://github.com/golang/go/blob/go1.26.6/src/internal/sync/hashtriemap.go#L521-L528) creates a new empty root and publishes it with one atomic store. The logical clear is small, while reclamation of the old tree is deferred to garbage collection.

### Memory Ordering And Linearization

The public `sync.Map` contract states that a write synchronizes before a read that observes it. The atomic child and root stores are publication points: the entry or subtree is fully initialized before its pointer becomes visible. Atomic loads then give readers a complete published object.

Local node mutexes serialize conflicting writers and protect structural decisions. They do not make one global snapshot of the whole trie, which is why independent branches can progress concurrently and why `Range` has weaker snapshot guarantees.

The practical distinction is:

```text
Load:       hash + atomic traversal, no steady-state mutex
same key:   serialized at the same local node
other keys: may proceed through different local nodes
new keys:   may allocate entries and expand the trie
```

### Connecting Source To Results

The source explains the benchmark shape:

- Stable, read-heavy keys benefit from the mutex-free `Load` path. In this run, `syncmap` reaches about `3.4 ns/op` at `-cpu=8`.
- Uniform writes across 1,000 keys can reach different trie regions, so `sync.Map` scales much better than a single global lock despite allocating replacement entries.
- A single hot key sends every writer to the same local node. The optimistic traversal cannot remove that serialization, and `syncmap` reaches `107.7 ns/op` in the 100% hot-write workload at `-cpu=8`.
- Continuous new-key insertion exercises entry allocation and trie expansion, producing `3 allocs/op` for `syncmap` in this run.
- Increasing the hand-written map from 4 to 128 shards reduces unrelated-key lock contention, but it does not change the trie internals of `sync.Map` and does not solve a single hot-key bottleneck.

These details are implementation-specific. Older Go versions used the `readOnly` map, `dirty` map, and miss-promotion design. Recheck the source for the exact Go version before using implementation details to explain application behavior.

## Practical Boundaries

Consider `sync.Map` when:

- A key is read many times after it is written.
- The key set is relatively stable, with frequent value updates but not constant creation of new keys.
- Multiple goroutines mostly operate on different keys.
- You accept the readability and type-assertion cost of `Load` returning `any`.

Consider `map + RWMutex` or a sharded map when:

- You need a strongly typed API.
- You need to combine multiple map operations into one atomic critical section.
- You need to maintain extra state, such as capacity, expiration time, or a reverse index.
- The write ratio is high, or you need more control over memory and lifecycle.

Consider `map + Mutex` when:

- The critical section is very small.
- Concurrency is low.
- The code path is not hot.
- Simplicity matters more than maximum throughput.

## Common Misconceptions

- Assuming `sync.Map` is the default choice for every concurrent map.
- Looking only at read-heavy ratios without checking whether keys are stable.
- Looking only at a local benchmark while ignoring code complexity and maintenance cost.
- Ignoring local contention caused by hot keys.
- Ignoring that Go version changes may affect implementation details and performance.

## Summary

Do not reduce the question to "is `sync.Map` fast?" Better questions are:

- Are keys stable, or are new keys constantly created?
- What is the read/write ratio?
- Is access uniformly distributed, or concentrated on a few hot keys?
- Do you need composed operations, a strongly typed wrapper, or extra state?
- Is map contention actually the current bottleneck?

Benchmark numbers become useful only after these conditions are clear.
