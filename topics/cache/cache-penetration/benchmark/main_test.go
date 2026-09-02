package main

import (
	"testing"
	"time"
)

func TestBloomFilterHasNoFalseNegatives(t *testing.T) {
	filter := newBloomFilter(1000, 8)
	for key := range 1000 {
		filter.add(uint64(key))
	}
	for key := range 1000 {
		if !filter.mightContain(uint64(key)) {
			t.Fatalf("filter rejected inserted key %d", key)
		}
	}
}

func TestNegativeCachingDependsOnKeyReuse(t *testing.T) {
	workloadCases := workloads(1000, 100, 10)
	negative := strategy{name: "negative", cacheMissing: true}

	repeated := run(workloadCases[0], negative, 1000, time.Millisecond)
	if repeated.originCalls != 10 || repeated.negativeEntries != 10 || repeated.negativeHits != 90 {
		t.Fatalf("repeated result = %+v, want 10 calls, 10 entries, and 90 negative hits", repeated)
	}

	unique := run(workloadCases[1], negative, 1000, time.Millisecond)
	if unique.originCalls != 100 || unique.negativeEntries != 100 || unique.negativeHits != 0 {
		t.Fatalf("unique result = %+v, want 100 calls, 100 entries, and no negative hits", unique)
	}
}

func TestBloomAndNegativeCachingAreComplementary(t *testing.T) {
	w := workloads(1000, 100, 10)[0]
	bloomOnly := run(w, strategy{name: "bloom", bitsPerItem: 8}, 1000, time.Millisecond)
	combined := run(w, strategy{name: "combined", bitsPerItem: 8, cacheMissing: true}, 1000, time.Millisecond)

	if bloomOnly.bloomRejected+bloomOnly.bloomFalsePos != len(w.keys) {
		t.Fatal("Bloom outcomes do not account for every request")
	}
	if combined.originCalls > bloomOnly.originCalls {
		t.Fatalf("combined origin calls = %d, bloom-only calls = %d", combined.originCalls, bloomOnly.originCalls)
	}
	if combined.bloomFalsePos != bloomOnly.bloomFalsePos {
		t.Fatal("negative caching changed Bloom filter outcomes")
	}
}
