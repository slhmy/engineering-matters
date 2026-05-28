# Go sync map

This topic uses a small experiment to compare several concurrent map strategies in Go: `map + sync.Mutex`, `map + sync.RWMutex`, `sync.Map`, and a sharded map.

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
| Sharded map | Spread keys across multiple locks. | Does sharding reduce contention when keys are well distributed? |

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
go test -bench=. -benchmem -benchtime=1s -cpu=1,8
```

The experiment compares four implementations:

- `mutex`
- `rwmutex`
- `syncmap`
- `shard32`

It varies these factors:

- 99% reads, 1% writes.
- 90% reads, 10% writes.
- 50% reads, 50% writes.
- 10% reads, 90% writes.
- 1,000 stable keys.
- Hot-key access.
- Inserting a new key on every write.

Observed metrics:

- Time per operation.
- Throughput.
- Memory allocation.
- Behavior under different concurrency levels.
- Lock contention under hot keys.

## How To Read The Results

This repository records one local run:

```text
topics/go/sync-map/result/2026-05-28-darwin-arm64.md
```

Do not read this kind of benchmark as a single "which row is fastest" ranking. Read the shape:

- With `-cpu=1`, there is little lock contention, so the overhead of extra mechanisms is easier to see.
- With `-cpu=8`, contention increases, and the differences among sharding, read/write locks, and `sync.Map` become more visible.
- As the write ratio rises, the read-sharing advantage of `RWMutex` weakens.
- When access concentrates on a few keys, a sharded map can still degrade into queues on a small number of shards.
- When the workload keeps inserting new keys, `sync.Map` is no longer only hitting its stable read path.

## Explanation

`sync.Map` is usually better suited to read-heavy workloads where keys are relatively stable and each key is written once but read many times. Its goal is not to replace every `map + lock` implementation; it targets the two common patterns described by the standard library documentation: write-once-read-many, and multiple goroutines reading or writing mostly disjoint key sets.

`map + RWMutex` is intuitive in read-heavy cases because readers can proceed concurrently. Once writes become more frequent, though, the write lock blocks new readers, and the read/write lock itself has management overhead.

`map + Mutex` is simple and often good enough when concurrency pressure is low or the critical section is tiny.

A sharded map can reduce contention on a single lock, but it adds implementation complexity and depends on a suitable hash function and shard count.

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
