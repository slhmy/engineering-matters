package main

import (
	"flag"
	"fmt"
	"math"
	"math/rand"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type expiryMode string

const (
	aligned   expiryMode = "aligned"
	jittered  expiryMode = "jittered"
	staggered expiryMode = "staggered"
)

type loadCall struct {
	done chan struct{}
}

type cacheEntry struct {
	mu        sync.RWMutex
	expiresAt time.Time

	loadMu sync.Mutex
	load   *loadCall
}

func (e *cacheEntry) get(o *origin, freshTTL time.Duration) {
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

	e.mu.RLock()
	fresh = time.Now().Before(e.expiresAt)
	e.mu.RUnlock()
	if fresh {
		e.loadMu.Unlock()
		return
	}

	call := &loadCall{done: make(chan struct{})}
	e.load = call
	e.loadMu.Unlock()

	o.load()
	e.mu.Lock()
	e.expiresAt = time.Now().Add(freshTTL)
	e.mu.Unlock()

	e.loadMu.Lock()
	e.load = nil
	close(call.done)
	e.loadMu.Unlock()
}

type origin struct {
	delay    time.Duration
	capacity int
	sem      chan struct{}
	started  time.Time
	bucket   time.Duration

	calls       atomic.Int64
	active      atomic.Int64
	peakActive  atomic.Int64
	waiting     atomic.Int64
	peakWaiting atomic.Int64

	metricsMu  sync.Mutex
	queueWaits []time.Duration
	buckets    map[int]int
	firstStart time.Time
	lastStart  time.Time
}

func newOrigin(delay time.Duration, capacity int, started time.Time, bucket time.Duration) *origin {
	o := &origin{
		delay:    delay,
		capacity: capacity,
		started:  started,
		bucket:   bucket,
		buckets:  make(map[int]int),
	}
	if capacity > 0 {
		o.sem = make(chan struct{}, capacity)
	}
	return o
}

func (o *origin) load() {
	attemptedAt := time.Now()
	o.calls.Add(1)
	o.recordAttempt(attemptedAt)

	var queueWait time.Duration
	if o.sem != nil {
		queuedAt := time.Now()
		select {
		case o.sem <- struct{}{}:
		default:
			waiting := o.waiting.Add(1)
			updatePeak(&o.peakWaiting, waiting)
			o.sem <- struct{}{}
			o.waiting.Add(-1)
		}
		queueWait = time.Since(queuedAt)
	}

	active := o.active.Add(1)
	updatePeak(&o.peakActive, active)
	time.Sleep(o.delay)
	o.active.Add(-1)
	if o.sem != nil {
		<-o.sem
	}

	o.metricsMu.Lock()
	o.queueWaits = append(o.queueWaits, queueWait)
	o.metricsMu.Unlock()
}

func (o *origin) recordAttempt(at time.Time) {
	bucket := int(at.Sub(o.started) / o.bucket)
	o.metricsMu.Lock()
	o.buckets[bucket]++
	if o.firstStart.IsZero() || at.Before(o.firstStart) {
		o.firstStart = at
	}
	if at.After(o.lastStart) {
		o.lastStart = at
	}
	o.metricsMu.Unlock()
}

func updatePeak(peak *atomic.Int64, value int64) {
	for {
		current := peak.Load()
		if value <= current || peak.CompareAndSwap(current, value) {
			return
		}
	}
}

func expiryOffsets(mode expiryMode, keys int, window time.Duration, seed int64) []time.Duration {
	offsets := make([]time.Duration, keys)
	switch mode {
	case aligned:
		return offsets
	case jittered:
		rng := rand.New(rand.NewSource(seed))
		for i := range offsets {
			offsets[i] = time.Duration(rng.Int63n(int64(window) + 1))
		}
	case staggered:
		if keys == 1 {
			return offsets
		}
		for i := range offsets {
			offsets[i] = time.Duration(i) * window / time.Duration(keys-1)
		}
	default:
		panic("unknown expiry mode: " + mode)
	}
	return offsets
}

type runResult struct {
	calls          int64
	peakActive     int64
	peakWaiting    int64
	maxBucketLoads int
	p99QueueWait   time.Duration
	startSpan      time.Duration
}

func run(mode expiryMode, keys int, baseTTL, window, requestInterval, originLatency time.Duration, capacity int, seed int64) runResult {
	started := time.Now()
	offsets := expiryOffsets(mode, keys, window, seed)
	entries := make([]cacheEntry, keys)
	for i := range entries {
		entries[i].expiresAt = started.Add(baseTTL + offsets[i])
	}
	o := newOrigin(originLatency, capacity, started, requestInterval)
	endAt := started.Add(baseTTL + window + requestInterval)
	freshTTL := time.Hour
	ticker := time.NewTicker(requestInterval)
	defer ticker.Stop()
	var requests sync.WaitGroup

	for now := range ticker.C {
		for i := range entries {
			requests.Add(1)
			go func(entry *cacheEntry) {
				defer requests.Done()
				entry.get(o, freshTTL)
			}(&entries[i])
		}
		if !now.Before(endAt) {
			break
		}
	}
	requests.Wait()

	o.metricsMu.Lock()
	queueWaits := append([]time.Duration(nil), o.queueWaits...)
	maxBucketLoads := 0
	for _, count := range o.buckets {
		if count > maxBucketLoads {
			maxBucketLoads = count
		}
	}
	startSpan := o.lastStart.Sub(o.firstStart)
	o.metricsMu.Unlock()
	sort.Slice(queueWaits, func(i, j int) bool { return queueWaits[i] < queueWaits[j] })

	return runResult{
		calls:          o.calls.Load(),
		peakActive:     o.peakActive.Load(),
		peakWaiting:    o.peakWaiting.Load(),
		maxBucketLoads: maxBucketLoads,
		p99QueueWait:   percentile(queueWaits, 0.99),
		startSpan:      startSpan,
	}
}

type summary struct {
	mode            expiryMode
	capacity        int
	calls           float64
	peakActive      float64
	peakWaiting     float64
	maxBucketLoads  float64
	p99QueueWait    time.Duration
	originStartSpan time.Duration
}

func summarize(mode expiryMode, keys int, baseTTL, window, requestInterval, originLatency time.Duration, capacity, repeats int, seed int64) summary {
	var calls, peakActive, peakWaiting, maxBucketLoads int64
	var p99QueueWait, originStartSpan time.Duration
	for repeat := range repeats {
		result := run(mode, keys, baseTTL, window, requestInterval, originLatency, capacity, seed+int64(repeat))
		calls += result.calls
		peakActive += result.peakActive
		peakWaiting += result.peakWaiting
		maxBucketLoads += int64(result.maxBucketLoads)
		p99QueueWait += result.p99QueueWait
		originStartSpan += result.startSpan
	}
	return summary{
		mode:            mode,
		capacity:        capacity,
		calls:           float64(calls) / float64(repeats),
		peakActive:      float64(peakActive) / float64(repeats),
		peakWaiting:     float64(peakWaiting) / float64(repeats),
		maxBucketLoads:  float64(maxBucketLoads) / float64(repeats),
		p99QueueWait:    p99QueueWait / time.Duration(repeats),
		originStartSpan: originStartSpan / time.Duration(repeats),
	}
}

func percentile(values []time.Duration, p float64) time.Duration {
	if len(values) == 0 {
		return 0
	}
	index := int(math.Ceil(float64(len(values))*p)) - 1
	return values[index]
}

func formatDuration(value time.Duration) string {
	if value < time.Microsecond {
		return value.Round(time.Nanosecond).String()
	}
	return value.Round(time.Microsecond).String()
}

func parseCapacities(input string) ([]int, error) {
	parts := strings.Split(input, ",")
	capacities := make([]int, 0, len(parts))
	for _, part := range parts {
		capacity, err := strconv.Atoi(strings.TrimSpace(part))
		if err != nil || capacity < 0 {
			return nil, fmt.Errorf("invalid non-negative capacity %q", part)
		}
		capacities = append(capacities, capacity)
	}
	return capacities, nil
}

func main() {
	keys := flag.Int("keys", 1000, "number of independently cached hot keys")
	baseTTL := flag.Duration("base-ttl", 100*time.Millisecond, "time before the first key expires")
	window := flag.Duration("spread-window", 500*time.Millisecond, "jitter and staggering window")
	requestInterval := flag.Duration("request-interval", 10*time.Millisecond, "interval between reads of every key")
	originLatency := flag.Duration("origin-latency", 20*time.Millisecond, "duration of one origin load")
	capacityFlag := flag.String("origin-capacity", "0,50", "comma-separated origin concurrency limits; 0 is unlimited")
	repeats := flag.Int("repeats", 3, "number of runs per case")
	seed := flag.Int64("seed", 1, "base random seed for jitter")
	flag.Parse()

	capacities, err := parseCapacities(*capacityFlag)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if *keys <= 0 || *baseTTL <= 0 || *window <= 0 || *requestInterval <= 0 || *originLatency <= 0 || *repeats <= 0 {
		fmt.Fprintln(os.Stderr, "keys, durations, and repeats must be positive")
		os.Exit(2)
	}

	fmt.Printf("Origin attempt bucket: %s\n\n", *requestInterval)
	fmt.Println("| Expiry schedule | Origin capacity | Origin calls | Max attempts/bucket | Attempt span | Peak active | Peak queued | P99 queue wait |")
	fmt.Println("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
	for _, capacity := range capacities {
		for _, mode := range []expiryMode{aligned, jittered, staggered} {
			result := summarize(mode, *keys, *baseTTL, *window, *requestInterval, *originLatency, capacity, *repeats, *seed)
			capacityLabel := strconv.Itoa(result.capacity)
			if result.capacity == 0 {
				capacityLabel = "unlimited"
			}
			fmt.Printf("| %s | %s | %.1f | %.1f | %s | %.1f | %.1f | %s |\n",
				result.mode,
				capacityLabel,
				result.calls,
				result.maxBucketLoads,
				formatDuration(result.originStartSpan),
				result.peakActive,
				result.peakWaiting,
				formatDuration(result.p99QueueWait),
			)
		}
	}
}
