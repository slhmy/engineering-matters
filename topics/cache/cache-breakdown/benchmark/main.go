package main

import (
	"flag"
	"fmt"
	"math"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type strategy string

const (
	naive        strategy = "naive"
	singleflight strategy = "singleflight"
	staleRefresh strategy = "swr"
)

type entry struct {
	value     string
	expiresAt time.Time
}

type loadCall struct {
	done  chan struct{}
	value string
}

type cache struct {
	mu    sync.RWMutex
	entry entry
	has   bool

	loadMu sync.Mutex
	load   *loadCall

	refreshMu  sync.Mutex
	refreshing bool
	background sync.WaitGroup
}

func (c *cache) seedExpired(value string) {
	c.mu.Lock()
	c.entry = entry{value: value, expiresAt: time.Now().Add(-time.Second)}
	c.has = true
	c.mu.Unlock()
}

func (c *cache) lookup() (entry, bool) {
	c.mu.RLock()
	e, ok := c.entry, c.has
	c.mu.RUnlock()
	return e, ok
}

func (c *cache) store(value string, ttl time.Duration) {
	c.mu.Lock()
	c.entry = entry{value: value, expiresAt: time.Now().Add(ttl)}
	c.has = true
	c.mu.Unlock()
}

func (c *cache) get(s strategy, origin *origin, ttl time.Duration) string {
	e, ok := c.lookup()
	if ok && time.Now().Before(e.expiresAt) {
		return e.value
	}

	switch s {
	case naive:
		value := origin.load()
		c.store(value, ttl)
		return value
	case singleflight:
		return c.loadOnce(origin, ttl)
	case staleRefresh:
		if ok {
			c.refresh(origin, ttl)
			return e.value
		}
		return c.loadOnce(origin, ttl)
	default:
		panic("unknown strategy: " + s)
	}
}

func (c *cache) loadOnce(origin *origin, ttl time.Duration) string {
	c.loadMu.Lock()
	if call := c.load; call != nil {
		c.loadMu.Unlock()
		<-call.done
		return call.value
	}
	if e, ok := c.lookup(); ok && time.Now().Before(e.expiresAt) {
		c.loadMu.Unlock()
		return e.value
	}

	call := &loadCall{done: make(chan struct{})}
	c.load = call
	c.loadMu.Unlock()

	call.value = origin.load()
	c.store(call.value, ttl)

	c.loadMu.Lock()
	c.load = nil
	close(call.done)
	c.loadMu.Unlock()
	return call.value
}

func (c *cache) refresh(origin *origin, ttl time.Duration) {
	c.refreshMu.Lock()
	if c.refreshing {
		c.refreshMu.Unlock()
		return
	}
	c.refreshing = true
	c.background.Add(1)
	c.refreshMu.Unlock()

	go func() {
		defer c.background.Done()
		c.store(origin.load(), ttl)
		c.refreshMu.Lock()
		c.refreshing = false
		c.refreshMu.Unlock()
	}()
}

func (c *cache) wait() {
	c.background.Wait()
}

type origin struct {
	delay   time.Duration
	calls   atomic.Int64
	active  atomic.Int64
	peak    atomic.Int64
	valueID atomic.Int64
}

func (o *origin) load() string {
	o.calls.Add(1)
	active := o.active.Add(1)
	for {
		peak := o.peak.Load()
		if active <= peak || o.peak.CompareAndSwap(peak, active) {
			break
		}
	}
	time.Sleep(o.delay)
	o.active.Add(-1)
	return fmt.Sprintf("fresh-%d", o.valueID.Add(1))
}

type sample struct {
	latency time.Duration
	stale   bool
}

type runResult struct {
	elapsed time.Duration
	samples []sample
	calls   int64
	peak    int64
}

func runWave(s strategy, concurrency int, originDelay time.Duration, ttl time.Duration) runResult {
	c := &cache{}
	c.seedExpired("stale")
	o := &origin{delay: originDelay}
	start := make(chan struct{})
	results := make(chan sample, concurrency)
	var ready, requests sync.WaitGroup
	ready.Add(concurrency)
	requests.Add(concurrency)

	for range concurrency {
		go func() {
			defer requests.Done()
			ready.Done()
			<-start
			began := time.Now()
			value := c.get(s, o, ttl)
			results <- sample{latency: time.Since(began), stale: value == "stale"}
		}()
	}

	ready.Wait()
	began := time.Now()
	close(start)
	requests.Wait()
	elapsed := time.Since(began)
	close(results)
	c.wait()

	result := runResult{elapsed: elapsed, calls: o.calls.Load(), peak: o.peak.Load()}
	for measurement := range results {
		result.samples = append(result.samples, measurement)
	}
	return result
}

type summary struct {
	strategy    strategy
	concurrency int
	delay       time.Duration
	throughput  float64
	p50         time.Duration
	p95         time.Duration
	p99         time.Duration
	originCalls float64
	originPeak  float64
	staleRatio  float64
}

func summarize(s strategy, concurrency int, delay time.Duration, repeats int, ttl time.Duration) summary {
	var latencies []time.Duration
	var elapsed time.Duration
	var calls, peak int64
	var stale int
	for range repeats {
		result := runWave(s, concurrency, delay, ttl)
		elapsed += result.elapsed
		calls += result.calls
		peak += result.peak
		for _, measurement := range result.samples {
			latencies = append(latencies, measurement.latency)
			if measurement.stale {
				stale++
			}
		}
	}
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	return summary{
		strategy:    s,
		concurrency: concurrency,
		delay:       delay,
		throughput:  float64(concurrency*repeats) / elapsed.Seconds(),
		p50:         percentile(latencies, 0.50),
		p95:         percentile(latencies, 0.95),
		p99:         percentile(latencies, 0.99),
		originCalls: float64(calls) / float64(repeats),
		originPeak:  float64(peak) / float64(repeats),
		staleRatio:  float64(stale) / float64(len(latencies)),
	}
}

func percentile(values []time.Duration, p float64) time.Duration {
	index := int(math.Ceil(float64(len(values))*p)) - 1
	return values[index]
}

func formatDuration(value time.Duration) string {
	if value < time.Microsecond {
		return value.Round(time.Nanosecond).String()
	}
	return value.Round(time.Microsecond).String()
}

func parseInts(input string) ([]int, error) {
	parts := strings.Split(input, ",")
	values := make([]int, 0, len(parts))
	for _, part := range parts {
		value, err := strconv.Atoi(strings.TrimSpace(part))
		if err != nil || value <= 0 {
			return nil, fmt.Errorf("invalid positive integer %q", part)
		}
		values = append(values, value)
	}
	return values, nil
}

func parseDurations(input string) ([]time.Duration, error) {
	parts := strings.Split(input, ",")
	values := make([]time.Duration, 0, len(parts))
	for _, part := range parts {
		value, err := time.ParseDuration(strings.TrimSpace(part))
		if err != nil || value <= 0 {
			return nil, fmt.Errorf("invalid positive duration %q", part)
		}
		values = append(values, value)
	}
	return values, nil
}

func main() {
	concurrencyFlag := flag.String("concurrency", "1,10,100,1000", "comma-separated concurrent request counts")
	delayFlag := flag.String("origin-latency", "10ms,100ms", "comma-separated origin latencies")
	repeats := flag.Int("repeats", 5, "number of expiry waves per case")
	ttl := flag.Duration("ttl", time.Minute, "TTL assigned to refreshed values")
	flag.Parse()

	concurrencies, err := parseInts(*concurrencyFlag)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	delays, err := parseDurations(*delayFlag)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if *repeats <= 0 || *ttl <= 0 {
		fmt.Fprintln(os.Stderr, "repeats and ttl must be positive")
		os.Exit(2)
	}

	fmt.Println("| Strategy | Concurrency | Origin latency | Requests/s | P50 | P95 | P99 | Origin calls/wave | Peak origin concurrency | Stale responses |")
	fmt.Println("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
	for _, delay := range delays {
		for _, concurrency := range concurrencies {
			for _, s := range []strategy{naive, singleflight, staleRefresh} {
				result := summarize(s, concurrency, delay, *repeats, *ttl)
				fmt.Printf("| %s | %d | %s | %.0f | %s | %s | %s | %.1f | %.1f | %.1f%% |\n",
					result.strategy,
					result.concurrency,
					result.delay,
					result.throughput,
					formatDuration(result.p50),
					formatDuration(result.p95),
					formatDuration(result.p99),
					result.originCalls,
					result.originPeak,
					result.staleRatio*100,
				)
			}
		}
	}
}
