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

## Explanation

`sync.Map` is usually better suited to read-heavy workloads where keys are relatively stable and each key is written once but read many times. Its goal is not to replace every `map + lock` implementation; it targets the two common patterns described by the standard library documentation: write-once-read-many, and multiple goroutines reading or writing mostly disjoint key sets.

`map + RWMutex` is intuitive in read-heavy cases because readers can proceed concurrently. Once writes become more frequent, though, the write lock blocks new readers, and the read/write lock itself has management overhead.

`map + Mutex` is simple and often good enough when concurrency pressure is low or the critical section is tiny.

A sharded map can reduce contention on a single lock, but it adds implementation complexity and depends on a suitable hash function and shard count. A third-party library such as `orcaman/concurrent-map` can remove some maintenance burden, but it is still a sharded-map design rather than a universally better replacement for `sync.Map`.

## Source Walkthrough

The benchmark uses Go 1.26.6. In this version, `sync.Map` is a thin wrapper around an internal generic `HashTrieMap` rather than a regular Go map protected by one global lock:

- [`sync.Map`](https://github.com/golang/go/blob/go1.26.6/src/sync/map.go) stores an `internal/sync.HashTrieMap[any, any]`.
- [`HashTrieMap`](https://github.com/golang/go/blob/go1.26.6/src/internal/sync/hashtriemap.go) is a concurrent hash trie.
- Each indirect trie node has 16 atomic child pointers and a mutex used when that part of the tree is changed.
- Leaf entries contain the key and value. An update publishes a new entry instead of mutating the entry currently visible to readers.

The read path is approximately:

```text
hash key
  -> atomically load root
  -> atomically follow trie children
  -> compare key in the leaf entry
  -> return value
```

After initialization, this path does not acquire a map mutex. Multiple readers can therefore traverse the structure at the same time, which explains the `syncmap` result of about `3.4 ns/op` at `-cpu=8` in the stable, read-heavy workload.

The write path is different:

```text
find target node without locking
  -> lock the affected trie node
  -> check that the node is still current
  -> create or replace an entry
  -> atomically publish the new pointer
```

The lock protects one part of the trie, not the whole map. Writes to unrelated keys can use different node locks, while writes to the same key still serialize. Replacing an entry also creates allocation and garbage-collection work; the benchmark reports this as `B/op` and `allocs/op` for `syncmap` writes.

This explains the shape of the experiment:

- Uniform writes across 1,000 keys can use different trie regions, so `sync.Map` and larger sharded maps scale better than a single global lock.
- Increasing a local sharded map from 4 to 128 shards reduces unrelated-key contention, but adds lock and memory overhead.
- A single hot key always reaches one trie region and one shard, so more shards do not remove that bottleneck. In this run, `syncmap` reached `107.7 ns/op` for that workload at `-cpu=8`.

Many older articles describe `sync.Map` using a `readOnly` map, a `dirty` map, and miss promotion. That describes an older implementation strategy. The exact internals are version-dependent, so source explanations should be checked against the Go version used by the benchmark.

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
