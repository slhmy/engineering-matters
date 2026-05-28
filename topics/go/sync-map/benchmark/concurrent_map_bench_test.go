package syncmapbench

import (
	"sync"
	"sync/atomic"
	"testing"
)

type concurrentMap interface {
	Load(key int) (int, bool)
	Store(key int, value int)
}

type mutexMap struct {
	mu sync.Mutex
	m  map[int]int
}

func newMutexMap(size int) *mutexMap {
	m := &mutexMap{m: make(map[int]int, size)}
	for i := 0; i < size; i++ {
		m.m[i] = i
	}
	return m
}

func (m *mutexMap) Load(key int) (int, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	v, ok := m.m[key]
	return v, ok
}

func (m *mutexMap) Store(key int, value int) {
	m.mu.Lock()
	m.m[key] = value
	m.mu.Unlock()
}

type rwMutexMap struct {
	mu sync.RWMutex
	m  map[int]int
}

func newRWMutexMap(size int) *rwMutexMap {
	m := &rwMutexMap{m: make(map[int]int, size)}
	for i := 0; i < size; i++ {
		m.m[i] = i
	}
	return m
}

func (m *rwMutexMap) Load(key int) (int, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	v, ok := m.m[key]
	return v, ok
}

func (m *rwMutexMap) Store(key int, value int) {
	m.mu.Lock()
	m.m[key] = value
	m.mu.Unlock()
}

type syncMap struct {
	m sync.Map
}

func newSyncMap(size int) *syncMap {
	m := &syncMap{}
	for i := 0; i < size; i++ {
		m.m.Store(i, i)
	}
	return m
}

func (m *syncMap) Load(key int) (int, bool) {
	v, ok := m.m.Load(key)
	if !ok {
		return 0, false
	}
	return v.(int), true
}

func (m *syncMap) Store(key int, value int) {
	m.m.Store(key, value)
}

type shardMap struct {
	shards []mapShard
}

type mapShard struct {
	mu sync.RWMutex
	m  map[int]int
}

func newShardMap(size int, shardCount int) *shardMap {
	m := &shardMap{
		shards: make([]mapShard, shardCount),
	}
	for i := range m.shards {
		m.shards[i].m = make(map[int]int, size/shardCount+1)
	}
	for i := 0; i < size; i++ {
		m.Store(i, i)
	}
	return m
}

func (m *shardMap) shardFor(key int) *mapShard {
	h := uint64(key) * 11400714819323198485
	return &m.shards[h%uint64(len(m.shards))]
}

func (m *shardMap) Load(key int) (int, bool) {
	s := m.shardFor(key)
	s.mu.RLock()
	defer s.mu.RUnlock()
	v, ok := s.m[key]
	return v, ok
}

func (m *shardMap) Store(key int, value int) {
	s := m.shardFor(key)
	s.mu.Lock()
	s.m[key] = value
	s.mu.Unlock()
}

type mapFactory struct {
	name string
	new  func(size int) concurrentMap
}

type workload struct {
	name       string
	readPct    int
	keySpace   int
	hotKeys    int
	insertOnly bool
}

var factories = []mapFactory{
	{name: "mutex", new: func(size int) concurrentMap { return newMutexMap(size) }},
	{name: "rwmutex", new: func(size int) concurrentMap { return newRWMutexMap(size) }},
	{name: "syncmap", new: func(size int) concurrentMap { return newSyncMap(size) }},
	{name: "shard32", new: func(size int) concurrentMap { return newShardMap(size, 32) }},
}

var workloads = []workload{
	{name: "read99_keys1k", readPct: 99, keySpace: 1_000},
	{name: "read90_keys1k", readPct: 90, keySpace: 1_000},
	{name: "read50_keys1k", readPct: 50, keySpace: 1_000},
	{name: "write90_keys1k", readPct: 10, keySpace: 1_000},
	{name: "read99_hot10", readPct: 99, keySpace: 1_000, hotKeys: 10},
	{name: "insert_new_keys", readPct: 0, keySpace: 1_000, insertOnly: true},
}

func BenchmarkConcurrentMap(b *testing.B) {
	for _, wl := range workloads {
		b.Run(wl.name, func(b *testing.B) {
			for _, factory := range factories {
				b.Run(factory.name, func(b *testing.B) {
					runWorkload(b, factory.new(wl.keySpace), wl)
				})
			}
		})
	}
}

func runWorkload(b *testing.B, m concurrentMap, wl workload) {
	b.ReportAllocs()
	var workerID atomic.Uint64
	var insertID atomic.Uint64

	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		id := workerID.Add(1)
		rng := newXorShift64(id*0x9e3779b97f4a7c15 + 1)
		for pb.Next() {
			if wl.insertOnly {
				key := wl.keySpace + int(insertID.Add(1))
				m.Store(key, key)
				continue
			}

			keyLimit := wl.keySpace
			if wl.hotKeys > 0 {
				keyLimit = wl.hotKeys
			}
			key := int(rng.next() % uint64(keyLimit))

			if int(rng.next()%100) < wl.readPct {
				_, _ = m.Load(key)
			} else {
				m.Store(key, key)
			}
		}
	})
}

type xorShift64 struct {
	x uint64
}

func newXorShift64(seed uint64) *xorShift64 {
	if seed == 0 {
		seed = 1
	}
	return &xorShift64{x: seed}
}

func (r *xorShift64) next() uint64 {
	x := r.x
	x ^= x << 13
	x ^= x >> 7
	x ^= x << 17
	r.x = x
	return x
}
