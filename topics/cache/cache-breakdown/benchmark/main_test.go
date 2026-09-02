package main

import (
	"sync"
	"testing"
	"time"
)

func TestSingleflightCoalescesExpiredKeyLoads(t *testing.T) {
	result := runWave(singleflight, 100, 10*time.Millisecond, time.Minute)

	if result.calls != 1 {
		t.Fatalf("origin calls = %d, want 1", result.calls)
	}
	if result.peak != 1 {
		t.Fatalf("peak origin concurrency = %d, want 1", result.peak)
	}
	for _, measurement := range result.samples {
		if measurement.stale {
			t.Fatal("singleflight returned a stale value")
		}
	}
}

func TestSingleflightRechecksCacheBeforeLoading(t *testing.T) {
	c := &cache{}
	c.store("fresh", time.Minute)
	o := &origin{delay: time.Millisecond}

	if got := c.loadOnce(o, time.Minute); got != "fresh" {
		t.Fatalf("value = %q, want fresh", got)
	}
	if calls := o.calls.Load(); calls != 0 {
		t.Fatalf("origin calls = %d, want 0", calls)
	}
}

func TestStaleWhileRevalidateReturnsStaleAndRefreshesOnce(t *testing.T) {
	result := runWave(staleRefresh, 100, 10*time.Millisecond, time.Minute)

	if result.calls != 1 {
		t.Fatalf("origin calls = %d, want 1", result.calls)
	}
	if result.peak != 1 {
		t.Fatalf("peak origin concurrency = %d, want 1", result.peak)
	}
	for _, measurement := range result.samples {
		if !measurement.stale {
			t.Fatal("stale-while-revalidate did not return the stale value")
		}
	}
}

func TestNaiveAllowsConcurrentOriginLoads(t *testing.T) {
	c := &cache{}
	c.seedExpired("stale")
	o := &origin{delay: 20 * time.Millisecond}
	start := make(chan struct{})
	var ready, requests sync.WaitGroup
	ready.Add(20)
	requests.Add(20)

	for range 20 {
		go func() {
			defer requests.Done()
			ready.Done()
			<-start
			c.get(naive, o, time.Minute)
		}()
	}

	ready.Wait()
	close(start)
	requests.Wait()
	if o.peak.Load() <= 1 {
		t.Fatalf("peak origin concurrency = %d, want more than 1", o.peak.Load())
	}
}

func TestParsersRejectInvalidValues(t *testing.T) {
	if _, err := parseInts("10,0"); err == nil {
		t.Fatal("parseInts accepted zero")
	}
	if _, err := parseDurations("10ms,nope"); err == nil {
		t.Fatal("parseDurations accepted an invalid duration")
	}
}

func TestPercentileUsesNearestRank(t *testing.T) {
	values := []time.Duration{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
	if got := percentile(values, 0.99); got != 10 {
		t.Fatalf("P99 = %d, want 10", got)
	}
}
